--- TPAP transport: Kasa and Tapo devices with Third-Party Compatibility off.
---
--- From the 1.4.0 firmware line, a device whose account has Third-Party
--- Compatibility off refuses the KLAP handshake (HTTP 403) and takes this login
--- instead. Like KLAP it is schema-agnostic: callers send the SMART or the IOT
--- JSON the device speaks and get its decoded answer.
---
--- Every refused password counts toward a device lock (15 tries), so a refused
--- one is never tried again until the credentials change, and a lock is waited
--- out.

local deferred = require("deferred")
local JSON = require("JSON")
local crypto = require("crypto")

local log = require("lib.logging")
local http = require("lib.http")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("lib.utils")

-- DriverWorks has lua-openssl from OS 3.4.1; the curve math is too slow
-- without it.
crypto.use_openssl(true)

--- @class TpapInfo
--- @field port integer The TPAP HTTP port.
--- @field tls integer 0 for plain HTTP.
--- @field pake integer[] Passcode types the device takes; 2 is the account password.

--- @class Tpap
--- @field _ip string? Device IP address.
--- @field _port integer TPAP HTTP port.
--- @field _username string? TP-Link account email.
--- @field _password string? TP-Link account password.
--- @field _connected boolean Whether a session is established.
--- @field _connecting Deferred? Login in flight, if any.
--- @field _stok string? Session token.
--- @field _key string? AES-128 session key.
--- @field _nonce string? First 8 bytes of the session nonce.
--- @field _seq integer? Sequence number of the next request.
--- @field _expiresAt number? Controller time (ms) to log in again by.
--- @field _refused string? Why the device refused the password, kept until the credentials change.
--- @field _lockedUntil number? Controller time (ms) the device's lock ends.
--- @field _queue table[] Requests waiting for the one in flight.
--- @field _busy boolean Whether a request is in flight.
local Tpap = {}
Tpap.__index = Tpap

--- HTTP timeout for device requests, in seconds.
local REQUEST_TIMEOUT_S = 10

--- The user name every login sends: MD5("admin").
local USERNAME_HASH = "21232f297a57a5a743894a0e4a801fc3"

--- The most PBKDF2 iterations a device may ask for, so a hostile
--- answer cannot stall the controller.
local MAX_ITERATIONS = 100000

--- Logging in again this long before the device's session ends.
local RENEW_EARLY_MS = ONE_MINUTE

--- A device can refuse a login straight after a session ends, so a new login
--- after a lost session waits this long.
local RELOGIN_DELAY_MS = 2 * ONE_SECOND

--- Error codes the device answers with.
local LOCKED = -2101
local REFUSED = -2203
local SESSION_LOST = -2402

local RAW = { return_encoding = "NONE", data_encoding = "NONE" }

--- @param n integer
--- @return string
local function packUint32BE(n)
  n = n % 4294967296
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- @param s string At least 4 bytes.
--- @return integer
local function unpackUint32BE(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

--- Compares two strings in time that does not depend on where they differ.
--- @param a string
--- @param b string
--- @return boolean
local function sameBytes(a, b)
  if #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then
      diff = diff + 1
    end
  end
  return diff == 0
end

--- Decodes a JSON body, or nil when it is not JSON. The URL library hands over
--- a device's JSON answer already decoded.
--- @param body string|table?
--- @return table?
local function decodeJson(body)
  if type(body) == "table" then
    return body
  end
  if IsEmpty(body) then
    return nil
  end
  local ok, decoded = pcall(JSON.decode, JSON, body)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

--- Runs fn in a coroutine, resuming it on a timer each time it yields, so no
--- slice holds the driver for longer than one scalar multiplication. fn
--- returns its result, or nil plus why it failed.
--- @param fn fun(): any?, string?
--- @return Deferred<any, { error: string }>
local function sliced(fn)
  local d = deferred.new()
  local co = coroutine.create(fn)
  local function resume()
    local ok, result, reason = coroutine.resume(co)
    if not ok then
      d:reject({ error = "TPAP: " .. tostring(result) })
    elseif coroutine.status(co) ~= "dead" then
      delay(1):next(resume)
    elseif result == nil then
      d:reject({ error = "TPAP: " .. tostring(reason) })
    else
      d:resolve(result)
    end
  end
  resume()
  return d
end

--- The credential the device's password transform asks for, or nil plus why
--- this driver cannot log in that way.
--- @param extraCrypt table?
--- @param password string
--- @return string? credential
--- @return string? reason
local function credentialFor(extraCrypt, password)
  local kind = Select(extraCrypt, "type")
  local passwdId = tointeger(Select(extraCrypt, "params", "passwd_id"))
  if kind == "password_shadow" and passwdId == 2 then
    local hex = C4:Hash("SHA1", password, { return_encoding = "HEX", data_encoding = "NONE" })
    return hex and string.lower(hex) or nil, hex == nil and "hashing the password failed" or nil
  elseif kind == "password_shadow" and passwdId == 4 then
    return password, nil
  end
  return nil,
    string.format(
      "the device asks for a password scheme this driver does not support (%s %s)",
      tostring(kind),
      tostring(passwdId)
    )
end

--- HKDF-SHA256 with the session's labels.
--- @param secret string K_shared.
--- @param label string "key" or "iv".
--- @param length integer
--- @return string
local function sessionKdf(secret, label, length)
  return crypto.hkdf.hkdf_sha256("tp-kdf-salt-aes128-" .. label, secret, "tp-kdf-info-aes128-" .. label, length)
end

--- Creates a new Tpap transport.
--- @return Tpap tpap A new transport.
function Tpap:new()
  log:trace("Tpap:new()")
  local instance = setmetatable({}, self)
  instance._connected = false
  instance._port = 80
  instance._queue = {}
  instance._busy = false
  return instance
end

--- Whether TPAP can run on this controller: it needs lua-openssl's bignums.
--- @return boolean available
--- @return string? reason
function Tpap.available()
  local ok, reason = crypto.spake2plus.is_accelerated()
  if not ok then
    log:debug("Tpap: unavailable: %s", reason)
  end
  return ok, reason
end

--- Asks a device whether it speaks TPAP. Resolves with its `tpap` object, or
--- nil when it answers but does not use TPAP (Third-Party Compatibility on,
--- or firmware from before TPAP). Rejects when the device does not answer,
--- and with `locked` set when it is locked after failed logins.
--- @param ip string
--- @param port? integer Defaults to 80.
--- @return Deferred<TpapInfo?, { error: string, code: integer?, locked: integer? }> info
function Tpap.discover(ip, port)
  log:trace("Tpap.discover(%s)", ip)
  local d = deferred.new()
  local url = string.format("http://%s:%d/", ip, port or 80)
  local body = JSON:encode({ method = "login", params = { sub_method = "discover" } })
  http
    :post(url, body, { ["Content-Type"] = "application/json" }, { timeout = REQUEST_TIMEOUT_S, cookies_enable = false })
    :next(function(response)
      local answer = decodeJson(response.body)
      local code = tointeger(Select(answer, "error_code"))
      if code == LOCKED then
        local minutes = tointeger(Select(answer, "error_info", "lockedMinute"))
        d:reject({ error = "TPAP: the device is locked after failed logins", locked = minutes })
        return
      end
      local info = Select(answer, "result", "tpap")
      if code ~= 0 or type(info) ~= "table" then
        d:resolve(nil)
        return
      end
      d:resolve({
        port = tointeger(info.port) or port or 80,
        tls = tointeger(info.tls) or 0,
        pake = type(info.pake) == "table" and info.pake or {},
      })
    end, function(err)
      d:reject({ error = Select(err, "error") or "TPAP: no answer to discover", code = Select(err, "code") })
    end)
  return d
end

--- Whether this transport can log in the way a device's `tpap` object asks:
--- plain HTTP, with the account password among its passcode types.
--- @param info TpapInfo
--- @return boolean supported
function Tpap.supports(info)
  if info.tls ~= 0 then
    return false
  end
  for _, pake in ipairs(info.pake or {}) do
    if tointeger(pake) == 2 then
      return true
    end
  end
  return false
end

--- Configures the transport. A change of device or account ends the session,
--- and a change of account lets a refused password be tried again.
--- @param config { ip: string?, port: integer?, username: string?, password: string? }
function Tpap:configure(config)
  log:trace("Tpap:configure(<ip=%s>)", config.ip)
  local deviceChanged = (config.ip ~= nil and config.ip ~= self._ip)
    or (config.port ~= nil and config.port ~= self._port)
  local accountChanged = (config.username ~= nil and config.username ~= self._username)
    or (config.password ~= nil and config.password ~= self._password)
  if config.ip ~= nil then
    self._ip = config.ip
  end
  if config.port ~= nil then
    self._port = config.port
  end
  if config.username ~= nil then
    self._username = config.username
  end
  if config.password ~= nil then
    self._password = config.password
  end
  if deviceChanged then
    self._lockedUntil = nil
  end
  if deviceChanged or accountChanged then
    self._refused = nil
    local dropped = self._connecting
    if dropped then
      self._connecting = nil
      dropped:reject({ error = "TPAP: connection reset" })
    end
  end
  self:reset()
end

--- Whether the transport currently has an established session.
--- @return boolean connected
function Tpap:isConnected()
  return self._connected == true
end

--- Discards the current session (a new login happens on the next request).
function Tpap:reset()
  log:trace("Tpap:reset()")
  self._connected = false
  self._stok = nil
  self._key = nil
  self._nonce = nil
  self._seq = nil
  self._expiresAt = nil
end

--- @private
--- @param path string
--- @return string
function Tpap:_url(path)
  return string.format("http://%s:%d%s", self._ip, self._port, path)
end

--- Sends one login step and decodes its answer.
--- @private
--- @param params table
--- @return Deferred<table, { error: string }>
function Tpap:_login(params)
  local body = JSON:encode({ method = "login", params = params })
  return http
    :post(self:_url("/"), body, { ["Content-Type"] = "application/json" }, {
      timeout = REQUEST_TIMEOUT_S,
      cookies_enable = false,
    })
    :next(function(response)
      local answer = decodeJson(response.body)
      if answer == nil then
        return deferred.new():reject({ error = "TPAP: " .. params.sub_method .. " answer is not JSON" })
      end
      return answer
    end)
end

--- Turns a login step's error code into the transport's rejection, keeping a
--- refusal and a lock so no further login is tried.
--- @private
--- @param answer table
--- @param step string
--- @return table err
function Tpap:_loginError(answer, step)
  local code = tointeger(answer.error_code)
  local info = Select(answer, "error_info") or {}
  local remaining = tointeger(info.remainAttempts)
  if code == LOCKED then
    local minutes = tointeger(info.lockedMinute)
    if minutes == nil or minutes <= 0 then
      minutes = 30
    end
    self._lockedUntil = C4:GetTime() + minutes * ONE_MINUTE
    return {
      error = string.format("TPAP: the device is locked for %d minutes after failed logins", minutes),
      locked = minutes,
    }
  elseif code == REFUSED then
    local message = "TPAP: the TP-Link account password was refused"
    if remaining ~= nil then
      message = string.format("%s (%d tries left before the device locks)", message, remaining)
    end
    self._refused = message .. "; change TP-Link Password to try again"
    return { error = self._refused, refused = true }
  end
  return { error = string.format("TPAP: the device refused %s (error %s)", step, tostring(code)), code = code }
end

--- Logs in. Concurrent callers share the same login in flight.
--- @return Deferred<Tpap, { error: string, refused: boolean?, locked: integer? }> session
function Tpap:connect()
  log:trace("Tpap:connect()")
  if self._connecting then
    return self._connecting
  end
  local d = deferred.new()
  if IsEmpty(self._ip) then
    return d:reject({ error = "TPAP: no IP address configured" })
  end
  if IsEmpty(self._password) then
    return d:reject({ error = "TPAP: no TP-Link password configured" })
  end
  if self._refused then
    return d:reject({ error = self._refused, refused = true })
  end
  if self._lockedUntil and C4:GetTime() < self._lockedUntil then
    local minutes = math.ceil((self._lockedUntil - C4:GetTime()) / ONE_MINUTE)
    return d:reject({
      error = string.format("TPAP: the device is locked for %d more minutes", minutes),
      locked = minutes,
    })
  end
  local available, why = Tpap.available()
  if not available then
    return d:reject({ error = "TPAP needs Control4 OS 3.4.1 or later (" .. tostring(why) .. ")" })
  end

  self._connecting = d
  self:reset()
  local superseded = { error = "TPAP: connection reset" }
  local p256 = crypto.p256
  local spake2plus = crypto.spake2plus
  local userRandom = crypto.random.bytes(32)

  self
    :_login({
      sub_method = "pake_register",
      username = USERNAME_HASH,
      user_random = C4:Base64Encode(userRandom),
      cipher_suites = { 1 },
      encryption = { "aes_128_ccm" },
      passcode_type = "userpw",
    })
    :next(function(answer)
      if self._connecting ~= d then
        return deferred.new():reject(superseded)
      end
      if tointeger(answer.error_code) ~= 0 then
        return deferred.new():reject(self:_loginError(answer, "pake_register"))
      end
      local result = answer.result or {}
      local devRandom = C4:Base64Decode(result.dev_random or "")
      local devSalt = C4:Base64Decode(result.dev_salt or "")
      local devShare = C4:Base64Decode(result.dev_share or "")
      local iterations = tointeger(result.iterations)
      if #devRandom ~= 32 or IsEmpty(devSalt) or IsEmpty(devShare) then
        return deferred.new():reject({ error = "TPAP: incomplete pake_register answer" })
      end
      if iterations == nil or iterations < 1 or iterations > MAX_ITERATIONS then
        return deferred.new():reject({ error = "TPAP: unexpected PBKDF2 iterations " .. tostring(result.iterations) })
      end
      local credential, unsupported = credentialFor(result.extra_crypt, self._password)
      if not credential then
        return deferred.new():reject({ error = "TPAP: " .. unsupported, unsupported = true })
      end
      local derived, err = C4:PBKDF2("SHA256", credential, devSalt, iterations, 80, {
        return_encoding = "NONE",
        salt_encoding = "NONE",
      })
      if not derived or #derived ~= 80 then
        return deferred.new():reject({ error = "TPAP: PBKDF2 failed: " .. tostring(err) })
      end
      local w0 = p256.reduce(string.sub(derived, 1, 40))
      local w1 = p256.reduce(string.sub(derived, 41, 80))
      local context = C4:Hash("SHA256", "PAKE V1" .. userRandom .. devRandom, RAW)
      local x = p256.random_scalar()
      local step = { step = coroutine.yield }
      return sliced(function()
        local share = spake2plus.prover_share(w0, x, step)
        local keys, keysErr = spake2plus.prover_finish(w0, w1, x, share, devShare, context, "", "", step)
        if not keys then
          return nil, keysErr or "SPAKE2+ failed"
        end
        keys.share = share
        return keys
      end)
    end)
    :next(function(keys)
      if self._connecting ~= d then
        return deferred.new():reject(superseded)
      end
      return self
        :_login({
          sub_method = "pake_share",
          user_share = C4:Base64Encode(keys.share),
          user_confirm = C4:Base64Encode(keys.prover_confirm),
        })
        :next(function(answer)
          if self._connecting ~= d then
            return deferred.new():reject(superseded)
          end
          if tointeger(answer.error_code) ~= 0 then
            return deferred.new():reject(self:_loginError(answer, "pake_share"))
          end
          local result = answer.result or {}
          local devConfirm = C4:Base64Decode(result.dev_confirm or "")
          if not sameBytes(devConfirm, keys.verifier_confirm) then
            return deferred.new():reject({ error = "TPAP: the device's confirmation did not match" })
          end
          local stok = result.stok or result.sessionId
          local startSeq = tointeger(result.start_seq)
          if IsEmpty(stok) or startSeq == nil then
            return deferred.new():reject({ error = "TPAP: incomplete pake_share answer" })
          end
          self._stok = tostring(stok)
          self._key = sessionKdf(keys.shared_key, "key", 16)
          self._nonce = string.sub(sessionKdf(keys.shared_key, "iv", 12), 1, 8)
          self._seq = startSeq % 4294967296
          local expired = tointeger(result.expired)
          self._expiresAt = (expired and expired > 0) and (C4:GetTime() + expired * ONE_SECOND - RENEW_EARLY_MS) or nil
          self._connected = true
          log:info("Tpap: session established with %s", self._ip)
          return self
        end)
    end)
    :next(function(result)
      self._connecting = nil
      d:resolve(result)
    end, function(err)
      if self._connecting ~= d then
        return
      end
      self._connecting = nil
      self:reset()
      log:warn("Tpap: login to %s failed: %s", self._ip, Select(err, "error") or err)
      d:reject(err)
    end)

  return d
end

--- Encrypts, sends and decrypts one request over the established session.
--- Rejects with `session` set when the device has ended the session.
--- @private
--- @param payload table
--- @return Deferred<table, { error: string, code: integer?, session: boolean? }>
function Tpap:_send(payload)
  local d = deferred.new()
  if not (self._key and self._nonce and self._seq and self._stok) then
    return d:reject({ error = "TPAP: no session established", session = true })
  end
  local seq = self._seq
  self._seq = (seq + 1) % 4294967296
  local seqBytes = packUint32BE(seq)
  local key = self._key
  local nonce = self._nonce .. seqBytes
  local sealed = crypto.aes_ccm.encrypt(key, nonce, JSON:encode(payload), "", 16)

  http
    :post(
      self:_url("/stok=" .. self._stok .. "/ds"),
      seqBytes .. sealed,
      { ["Content-Type"] = "application/octet-stream" },
      { timeout = REQUEST_TIMEOUT_S, cookies_enable = false }
    )
    :next(function(response)
      local body = response.body or ""
      -- Decrypted first: a sequence number can start with "{", so a body that
      -- looks like JSON is read as an error only when it is not this answer.
      if type(body) == "string" and #body >= 20 and unpackUint32BE(body) == seq then
        local plaintext = crypto.aes_ccm.decrypt(key, nonce, string.sub(body, 5), "", 16)
        local decoded = plaintext and decodeJson(plaintext)
        if decoded then
          d:resolve(decoded)
          return
        end
      end
      local answer = decodeJson(body)
      local code = tointeger(Select(answer, "error_code"))
      if code ~= nil then
        d:reject({
          error = "TPAP: request refused (error " .. code .. ")",
          code = code,
          session = code == SESSION_LOST or code == LOCKED,
        })
        return
      end
      d:reject({ error = "TPAP: the answer could not be read", session = true })
    end, function(err)
      -- The URL carries the session token, so the HTTP error text is not kept.
      local status = tointeger(Select(err, "code"))
      d:reject({
        error = (status and status > 0) and ("TPAP: the request failed (HTTP " .. status .. ")")
          or "TPAP: the device did not answer the request",
        code = status,
        session = status == 401 or status == 403,
      })
    end)
  return d
end

--- Sends one queued request, logging in first when there is no session or the
--- device's session is about to end, and once more after a lost session.
--- @private
--- @param payload table
--- @return Deferred<table, { error: string }>
function Tpap:_run(payload)
  local function send()
    return self:_send(payload)
  end
  local start
  if self._connected and (self._expiresAt == nil or C4:GetTime() < self._expiresAt) then
    start = send()
  else
    start = self:connect():next(send)
  end
  return start:next(nil, function(err)
    if not (Select(err, "session") and self._connected) then
      return deferred.new():reject(err)
    end
    log:debug("Tpap: session lost (%s); logging in again", Select(err, "error"))
    self:reset()
    return delay(RELOGIN_DELAY_MS):next(function()
      return self:connect():next(send)
    end)
  end)
end

--- Sends the next queued request when none is in flight.
--- @private
function Tpap:_pump()
  if self._busy or #self._queue == 0 then
    return
  end
  local entry = table.remove(self._queue, 1)
  self._busy = true
  self:_run(entry.payload):next(function(response)
    self._busy = false
    entry.done:resolve(response)
    self:_pump()
  end, function(err)
    self._busy = false
    entry.done:reject(err)
    self:_pump()
  end)
end

--- Sends a request. The device takes only the next sequence number, so
--- requests go out one at a time, in order.
--- @param payload table The JSON-encodable request payload (SMART or IOT schema).
--- @return Deferred<table, { error: string, code: integer?, refused: boolean?, locked: integer? }> answer
function Tpap:request(payload)
  log:trace("Tpap:request(%s)", payload)
  local done = deferred.new()
  table.insert(self._queue, { payload = payload, done = done })
  self:_pump()
  return done
end

return Tpap
