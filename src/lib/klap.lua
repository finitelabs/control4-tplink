--- KLAP v2 transport for TP-Link Kasa/Tapo devices.
---
--- Implements the KLAP handshake and encrypted request cycle used by Kasa
--- devices on post-2024 firmware. The transport is schema-agnostic: callers
--- provide the JSON payload (e.g. legacy IOT `{"system":{"get_sysinfo":{}}}`)
--- and receive the decoded JSON response.
---
--- Protocol summary:
---   1. POST /app/handshake1 with 16 random bytes (local_seed). The device
---      responds with 16 bytes (remote_seed) + 32 bytes
---      SHA256(local_seed .. remote_seed .. auth_hash), proving which
---      credentials it was provisioned with. auth_hash (v2) is
---      SHA256(SHA1(username) .. SHA1(password)).
---   2. POST /app/handshake2 with SHA256(remote_seed .. local_seed .. auth_hash).
---   3. Derive session keys:
---        key     = SHA256("lsk" .. seeds .. auth)[1..16]   (AES-128-CBC key)
---        iv/seq  = SHA256("iv"  .. seeds .. auth)          (iv = [1..12], seq = last 4 bytes as int32)
---        sig     = SHA256("ldk" .. seeds .. auth)[1..28]   (signature key)
---   4. Each request: seq += 1; iv = iv12 .. int32be(seq);
---      body = SHA256(sig .. int32be(seq) .. ciphertext) .. ciphertext
---      POST /app/request?seq=<seq>

local deferred = require("deferred")

local log = require("lib.logging")
local http = require("lib.http")

--- @class Klap
--- @field _ip string Device IP address.
--- @field _username string TP-Link account username (email, case sensitive).
--- @field _password string TP-Link account password.
--- @field _cookie string? Session cookie (TP_SESSIONID) from handshake1.
--- @field _key string? AES-128 key for the current session.
--- @field _iv string? 12-byte IV prefix for the current session.
--- @field _sig string? 28-byte signature key for the current session.
--- @field _seq number? Current request sequence number (signed int32).
--- @field _connected boolean Whether a session is established.
--- @field _connecting Deferred? In-flight handshake, if any.
local Klap = {}
Klap.__index = Klap

--- HTTP timeout for device requests, in seconds.
--- @type number
local REQUEST_TIMEOUT = 10

--- Hash options for raw-binary in / raw-binary out.
local RAW = { return_encoding = "NONE", data_encoding = "NONE" }

--- Cipher options for raw-binary key/iv/data with PKCS7 padding.
local CIPHER_OPTIONS = {
  return_encoding = "NONE",
  key_encoding = "NONE",
  iv_encoding = "NONE",
  data_encoding = "NONE",
  padding = true,
}

--- Packs a signed 32-bit integer as 4 bytes big-endian (two's complement).
--- @param n number
--- @return string
local function packInt32BE(n)
  n = n % 4294967296
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- Unpacks 4 bytes big-endian into a signed 32-bit integer.
--- @param s string At least 4 bytes.
--- @return number
local function unpackInt32BE(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  local n = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  if n >= 2147483648 then
    n = n - 4294967296
  end
  return n
end

--- Generates 16 random bytes.
--- @return string
local function randomSeed()
  local bytes = {}
  for i = 1, 16 do
    bytes[i] = string.char(math.random(0, 255))
  end
  return table.concat(bytes)
end

--- Extracts the TP_SESSIONID cookie from response headers.
--- @param headers table<string, string|string[]>?
--- @return string? cookie The "TP_SESSIONID=..." pair, or nil.
local function extractSessionCookie(headers)
  for name, value in pairs(headers or {}) do
    if string.lower(name) == "set-cookie" then
      local cookies = type(value) == "table" and value or { value }
      for _, cookie in ipairs(cookies) do
        local session = string.match(cookie, "(TP_SESSIONID=[^;]+)")
        if session then
          return session
        end
      end
    end
  end
  return nil
end

--- Creates a new Klap transport.
--- @return Klap
function Klap:new()
  log:trace("Klap:new()")
  local instance = setmetatable({}, self)
  instance._connected = false
  return instance
end

--- Configures the transport. Resets any established session on change.
--- @param config { ip: string?, username: string?, password: string? }
function Klap:configure(config)
  log:trace("Klap:configure(<ip=%s, username=%s>)", config.ip, config.username)
  if config.ip ~= nil then
    self._ip = config.ip
  end
  if config.username ~= nil then
    self._username = config.username
  end
  if config.password ~= nil then
    self._password = config.password
  end
  self:reset()
end

--- Whether the transport currently has an established session.
--- @return boolean
function Klap:isConnected()
  return self._connected == true
end

--- Discards the current session (a new handshake happens on the next request).
function Klap:reset()
  log:trace("Klap:reset()")
  self._connected = false
  self._cookie = nil
  self._key = nil
  self._iv = nil
  self._sig = nil
  self._seq = nil
end

--- Computes the KLAP v2 auth hash: SHA256(SHA1(username) .. SHA1(password)).
--- @private
--- @return string? authHash 32 raw bytes, or nil on error.
function Klap:_authHash()
  local userHash, err1 = C4:Hash("SHA1", self._username or "", RAW)
  local passHash, err2 = C4:Hash("SHA1", self._password or "", RAW)
  if not userHash or not passHash then
    log:error("Klap: hashing credentials failed: %s %s", err1, err2)
    return nil
  end
  return C4:Hash("SHA256", userHash .. passHash, RAW)
end

--- Base URL for the device.
--- @private
--- @return string
function Klap:_url(path)
  return string.format("http://%s%s", self._ip, path)
end

--- Performs the two-step KLAP handshake and derives session keys.
--- Concurrent callers share the same in-flight handshake.
--- @return Deferred<Klap, { error: string }>
function Klap:connect()
  log:trace("Klap:connect()")
  if self._connecting then
    return self._connecting
  end

  local d = deferred.new()

  if IsEmpty(self._ip) then
    return d:reject({ error = "Klap: no IP address configured" })
  end
  if IsEmpty(self._username) or IsEmpty(self._password) then
    return d:reject({ error = "Klap: no TP-Link credentials configured" })
  end

  local auth = self:_authHash()
  if not auth then
    return d:reject({ error = "Klap: failed to compute auth hash" })
  end

  self._connecting = d
  self:reset()

  local localSeed = randomSeed()

  http
    :post(self:_url("/app/handshake1"), localSeed, {}, { timeout = REQUEST_TIMEOUT, cookies_enable = false })
    :next(function(response)
      local body = response.body or ""
      if #body < 48 then
        return deferred.new():reject({ error = "Klap: short handshake1 response (" .. #body .. " bytes)" })
      end

      local remoteSeed = string.sub(body, 1, 16)
      local serverHash = string.sub(body, 17, 48)
      local expected = C4:Hash("SHA256", localSeed .. remoteSeed .. auth, RAW)

      if expected ~= serverHash then
        return deferred.new():reject({
          error = "Klap: handshake1 auth mismatch; device is bound to a different TP-Link account/password",
        })
      end

      self._cookie = extractSessionCookie(response.headers)
      local payload = C4:Hash("SHA256", remoteSeed .. localSeed .. auth, RAW)

      return http
        :post(
          self:_url("/app/handshake2"),
          payload,
          { Cookie = self._cookie },
          { timeout = REQUEST_TIMEOUT, cookies_enable = false }
        )
        :next(function()
          local seeds = localSeed .. remoteSeed .. auth
          self._key = string.sub(C4:Hash("SHA256", "lsk" .. seeds, RAW), 1, 16)
          local ivFull = C4:Hash("SHA256", "iv" .. seeds, RAW)
          self._iv = string.sub(ivFull, 1, 12)
          self._seq = unpackInt32BE(string.sub(ivFull, 29, 32))
          self._sig = string.sub(C4:Hash("SHA256", "ldk" .. seeds, RAW), 1, 28)
          self._connected = true
          log:info("Klap: session established with %s", self._ip)
          return self
        end)
    end)
    :next(function(result)
      self._connecting = nil
      d:resolve(result)
    end, function(err)
      self._connecting = nil
      self:reset()
      log:warn("Klap: handshake with %s failed: %s", self._ip, Select(err, "error") or err)
      d:reject(err)
    end)

  return d
end

--- Encrypts, sends, and decrypts one request over the established session.
--- @private
--- @param payload table The JSON-encodable request payload.
--- @return Deferred<table, { error: string, code: number? }>
function Klap:_send(payload)
  local d = deferred.new()

  if not (self._key and self._iv and self._sig and self._seq) then
    return d:reject({ error = "Klap: no session established" })
  end

  self._seq = self._seq + 1
  local seq = self._seq
  local seqBytes = packInt32BE(seq)
  local iv = self._iv .. seqBytes

  local plaintext = JSON:encode(payload)
  local ciphertext, encryptErr = C4:Encrypt("AES-128-CBC", self._key, iv, plaintext, CIPHER_OPTIONS)
  if not ciphertext then
    return d:reject({ error = "Klap: encryption failed: " .. tostring(encryptErr) })
  end

  local signature = C4:Hash("SHA256", self._sig .. seqBytes .. ciphertext, RAW)

  http
    :post(
      self:_url("/app/request?seq=" .. tostring(seq)),
      signature .. ciphertext,
      { Cookie = self._cookie },
      { timeout = REQUEST_TIMEOUT, cookies_enable = false }
    )
    :next(function(response)
      local body = response.body or ""
      local plaintextResponse, decryptErr =
        C4:Decrypt("AES-128-CBC", self._key, iv, string.sub(body, 33), CIPHER_OPTIONS)
      if not plaintextResponse then
        return d:reject({ error = "Klap: decryption failed: " .. tostring(decryptErr) })
      end
      local decoded = JSON:decode(plaintextResponse)
      if decoded == nil then
        return d:reject({ error = "Klap: response is not valid JSON: " .. tostring(plaintextResponse) })
      end
      d:resolve(decoded)
    end, function(err)
      d:reject({ error = Select(err, "error") or "Klap: request failed", code = Select(err, "code") })
    end)

  return d
end

--- Sends a request, establishing (or re-establishing) the session as needed.
--- A 403 response invalidates the session and triggers one handshake + retry.
--- @param payload table The JSON-encodable request payload (device schema, e.g. IOT).
--- @return Deferred<table, { error: string, code: number? }>
function Klap:request(payload)
  log:trace("Klap:request(%s)", payload)
  local d = deferred.new()

  local function send()
    return self:_send(payload)
  end

  local start
  if self._connected then
    start = send()
  else
    start = self:connect():next(send)
  end

  start:next(function(response)
    d:resolve(response)
  end, function(err)
    if Select(err, "code") == 403 and self._connected then
      -- Session expired on the device; re-handshake once and retry.
      log:debug("Klap: session rejected (403), re-handshaking")
      self:reset()
      self:connect():next(send):next(function(response)
        d:resolve(response)
      end, function(retryErr)
        d:reject(retryErr)
      end)
    else
      d:reject(err)
    end
  end)

  return d
end

return Klap
