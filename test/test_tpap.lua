--- Tests for tplink.tpap: the TPAP login (SPAKE2+ on P-256) and its AES-128-CCM
--- session, for a device whose account has Third-Party Compatibility off.
---
--- Run with: ./run_test.sh test_tpap.lua
---
--- The first section replays a fixed end-to-end vector byte for byte. The rest
--- run against an in-process stand-in device built on the crypto library's
--- SPAKE2+ verifier side, not on tplink/tpap.lua.

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.lib")

local crypto = require("crypto")
local Tpap = require("tplink.tpap")

if not C4.SHIM_HAS_CRYPTO then
  print("SKIP: no crypto backend in shim (run under LuaJIT with CommonCrypto/libcrypto)")
  os.exit(0)
end

local RAW = { return_encoding = "NONE", data_encoding = "NONE" }

local function hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

local function unhex(h)
  return (h:gsub("..", function(x)
    return string.char(tonumber(x, 16))
  end))
end

local function packUint32BE(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function unpackUint32BE(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

-- A controller runs the curve math on lua-openssl's bignums, and the transport
-- refuses without them. The desktop has no binding, so the library's pure-Lua
-- path stands in; the refusal itself is tested at the end.
local accelerated = crypto.spake2plus.is_accelerated
crypto.spake2plus.is_accelerated = function()
  return true
end

-- DriverWorks' PBKDF2, which the shim does not model.
function C4:PBKDF2(digest, password, salt, iterations, length)
  assert(digest == "SHA256", "the transport asks for PBKDF2-SHA256")
  return crypto.pbkdf2.derive("sha256", password, salt, iterations, length)
end

--- The controller's clock, moved by the tests.
local now = 1000000
function C4:GetTime()
  return now
end

--- Collects a deferred's outcome, firing timers until it settles (the login
--- runs one scalar multiplication per timer tick).
local function settle(d)
  local outcome = {}
  d:next(function(value)
    outcome.resolved = value
  end, function(err)
    outcome.rejected = err
  end)
  for _ = 1, 50 do
    if outcome.resolved ~= nil or outcome.rejected ~= nil then
      break
    end
    ShimFireTimers()
  end
  return outcome
end

--- Installs a device as the global urlDo.
local function install(device)
  function urlDo(_, url, data, _, callback)
    device.posts = (device.posts or 0) + 1
    local code, body = device:serve(url, data or "")
    if code >= 200 and code < 300 then
      callback(nil, code, {}, body, nil, url)
    else
      callback("HTTP " .. code, code, {}, body, nil, url)
    end
  end
end

local function b64(s)
  return C4:Base64Encode(s)
end

local function unb64(s)
  return C4:Base64Decode(s)
end

---------------------------------------------------------------------------
T.section("an end-to-end vector, byte for byte")
---------------------------------------------------------------------------

do
  -- The vector's own randomness.
  local randomBytes, randomScalar = crypto.random.bytes, crypto.p256.random_scalar
  crypto.random.bytes = function(n)
    assert(n == 32)
    return string.rep("\17", 32)
  end
  crypto.p256.random_scalar = function()
    return unhex(string.rep("0", 56) .. "3b9aca07")
  end

  local seen = {}
  local device = {}
  function device:serve(url, body)
    local path = url:match("^https?://[^/]+(/.*)$")
    if path == "/" then
      local request = JSON:decode(body)
      local params = request.params
      if params.sub_method == "pake_register" then
        seen.register = params
        return 200,
          JSON:encode({
            error_code = 0,
            result = {
              dev_random = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=",
              dev_salt = "AAECAwQFBgcICQoLDA0ODw==",
              dev_share = "BLLG2PUI/sFB1k+dg8GTn8dnNYpTGJmleA43ki+GS6CmsVMdONsEw+mpDdqJgQrWlBq4CDAbZK/cBixRLsWDMmU=",
              cipher_suites = 1,
              iterations = 3000,
              encryption = "aes_128_ccm",
              extra_crypt = { type = "password_shadow", params = { passwd_id = 2 } },
            },
          })
      elseif params.sub_method == "pake_share" then
        seen.share = params
        return 200,
          JSON:encode({
            error_code = 0,
            result = { dev_confirm = "lmjFxh34nRRATwuHhLglqHgfwdsHWkiMO5pTv9iD9mg=", stok = "STOK", start_seq = 7 },
          })
      end
    elseif path == "/stok=STOK/ds" then
      seen.body = body
      local key = unhex("6c822ab9a777697f0c1c2cf47d300030")
      local nonce = unhex("8c36175e46b6a460") .. string.sub(body, 1, 4)
      return 200, string.sub(body, 1, 4) .. crypto.aes_ccm.encrypt(key, nonce, '{"error_code":0,"result":{}}', "", 16)
    end
    return 404, ""
  end
  install(device)

  local tpap = Tpap:new()
  tpap:configure({ ip = "192.0.2.10", username = "user@example.com", password = "hunter2" })
  local outcome = settle(tpap:request({ method = "get_device_info" }))

  T.eq("the user name is MD5 of admin", Select(seen, "register", "username"), "21232f297a57a5a743894a0e4a801fc3")
  T.eq("the user random", Select(seen, "register", "user_random"), "ERERERERERERERERERERERERERERERERERERERERERE=")
  T.eq("the offer", {
    Select(seen, "register", "cipher_suites"),
    Select(seen, "register", "encryption"),
    Select(seen, "register", "passcode_type"),
  }, { { 1 }, { "aes_128_ccm" }, "userpw" })
  T.eq(
    "the share",
    Select(seen, "share", "user_share"),
    "BEtMQTFFYukP6H4+b7i3tVZo5zlz7qF3xXFSmkd7JkN39F0RJHs5HJEorQiLT020mSgJ1mUB53b2+YZMubwwvtI="
  )
  T.eq("the confirmation", Select(seen, "share", "user_confirm"), "SPrxQjzeqXXhHZcAWSsyRXXL+SYfMhL76oGzdvtB814=")
  T.eq(
    "the first request's body",
    seen.body and hex(seen.body),
    "00000007e63c49bad100faad079f8446916a96888feca5eb08e30f53713d4b4a52bcd5520f5f2a0f082d557265aac01e"
  )
  T.eq("the answer decrypted", outcome.resolved, { error_code = 0, result = {} })

  crypto.random.bytes, crypto.p256.random_scalar = randomBytes, randomScalar
end

---------------------------------------------------------------------------
-- A stand-in TPAP device on the crypto library's verifier side.
---------------------------------------------------------------------------

local PASSWORD = "correct horse"

--- @param opts table?
local function standIn(opts)
  opts = opts or {}
  local device = {
    password = opts.password or PASSWORD,
    extraCrypt = opts.extraCrypt or { type = "password_shadow", params = { passwd_id = 2 } },
    tpap = opts.tpap or { tls = 0, dac = 0, noc = 0, pake = { 2 }, port = 80 },
    salt = "0123456789abcdef",
    iterations = 3000,
    startSeq = opts.startSeq or 100,
    failures = 0,
    locked = nil,
    requests = {},
    sessions = 0,
    loseSession = false,
    badConfirm = opts.badConfirm,
  }

  local function credential()
    local kind = device.extraCrypt.params.passwd_id
    if kind == 4 then
      return device.password
    end
    return string.lower(C4:Hash("SHA1", device.password, { return_encoding = "HEX" }))
  end

  local function json(t)
    return 200, JSON:encode(t)
  end

  function device:serve(url, body)
    local path = url:match("^https?://[^/]+(/.*)$")
    if path == "/" then
      local params = JSON:decode(body).params
      if self.locked then
        return json({
          error_code = -2101,
          error_info = { lockedMinute = self.locked, failedAttempts = 15, remainAttempts = 0 },
        })
      end
      if params.sub_method == "discover" then
        return json({ error_code = 0, result = { sub_method = "discover", tpap_preferred = true, tpap = self.tpap } })
      elseif params.sub_method == "pake_register" then
        local dk = crypto.pbkdf2.derive("sha256", credential(), self.salt, self.iterations, 80)
        self.w0 = crypto.p256.reduce(string.sub(dk, 1, 40))
        self.L = crypto.spake2plus.registration(crypto.p256.reduce(string.sub(dk, 41, 80)))
        self.userRandom = unb64(params.user_random)
        self.devRandom = string.rep("\51", 32)
        self.y = crypto.p256.random_scalar()
        self.Y = crypto.spake2plus.verifier_share(self.w0, self.y)
        return json({
          error_code = 0,
          result = {
            dev_random = b64(self.devRandom),
            dev_salt = b64(self.salt),
            dev_share = b64(self.Y),
            cipher_suites = 1,
            iterations = self.iterations,
            encryption = "aes_128_ccm",
            extra_crypt = self.extraCrypt,
          },
        })
      elseif params.sub_method == "pake_share" then
        local X = unb64(params.user_share)
        local context = C4:Hash("SHA256", "PAKE V1" .. self.userRandom .. self.devRandom, RAW)
        local keys = crypto.spake2plus.verifier_finish(self.w0, self.L, self.y, X, self.Y, context, "", "")
        if not keys or unb64(params.user_confirm) ~= keys.prover_confirm then
          self.failures = self.failures + 1
          return json({
            error_code = -2203,
            error_info = { lockedMinute = 0, failedAttempts = self.failures, remainAttempts = 15 - self.failures },
          })
        end
        self.sessions = self.sessions + 1
        self.stok = "STOK" .. self.sessions
        self.key = crypto.hkdf.hkdf_sha256("tp-kdf-salt-aes128-key", keys.shared_key, "tp-kdf-info-aes128-key", 16)
        self.nonce = string.sub(
          crypto.hkdf.hkdf_sha256("tp-kdf-salt-aes128-iv", keys.shared_key, "tp-kdf-info-aes128-iv", 12),
          1,
          8
        )
        self.nextSeq = self.startSeq
        local confirm = self.badConfirm and string.rep("\0", 32) or keys.verifier_confirm
        return json({
          error_code = 0,
          result = { dev_confirm = b64(confirm), stok = self.stok, start_seq = self.startSeq, expired = 3600 },
        })
      end
      return json({ error_code = -1 })
    end
    local stok = path:match("^/stok=([^/]+)/ds$")
    if stok then
      if stok ~= self.stok or self.loseSession then
        self.loseSession = false
        self.stok = nil
        return json({ error_code = -2402 })
      end
      local seq = unpackUint32BE(body)
      if seq ~= self.nextSeq then
        return json({ error_code = -40401 })
      end
      self.nextSeq = (seq + 1) % 4294967296
      local nonce = self.nonce .. packUint32BE(seq)
      local plaintext = crypto.aes_ccm.decrypt(self.key, nonce, string.sub(body, 5), "", 16)
      local request = JSON:decode(plaintext)
      table.insert(self.requests, { seq = seq, method = request.method })
      local reply = JSON:encode({ error_code = 0, result = { method = request.method, seq = seq } })
      return 200, packUint32BE(seq) .. crypto.aes_ccm.encrypt(self.key, nonce, reply, "", 16)
    end
    return 404, ""
  end

  install(device)
  return device
end

local function transport(password)
  local tpap = Tpap:new()
  tpap:configure({ ip = "192.0.2.20", username = "user@example.com", password = password or PASSWORD })
  return tpap
end

---------------------------------------------------------------------------
T.section("discover tells a device on TPAP from one that is not")
---------------------------------------------------------------------------

do
  standIn()
  local found = settle(Tpap.discover("192.0.2.20"))
  T.eq("a device on TPAP", found.resolved, { port = 80, tls = 0, pake = { 2 } })
  T.truthy("which this transport can log in to", Tpap.supports(found.resolved))
  T.falsy("over TLS it cannot", Tpap.supports({ port = 443, tls = 1, pake = { 2 } }))
  T.falsy("nor with only the default passcode", Tpap.supports({ port = 80, tls = 0, pake = { 0 } }))

  install({
    serve = function()
      return 200, JSON:encode({ error_code = 0, result = { sub_method = "discover", tpap_preferred = false } })
    end,
  })
  T.eq("Third-Party Compatibility on: not TPAP", settle(Tpap.discover("192.0.2.20")).rejected, nil)
  install({
    serve = function()
      return 200, "<html><body><center>200 OK</center></body></html>"
    end,
  })
  local older = settle(Tpap.discover("192.0.2.20"))
  T.eq("firmware from before TPAP: not TPAP", { older.resolved, older.rejected }, {})
end

---------------------------------------------------------------------------
T.section("a login and requests in order")
---------------------------------------------------------------------------

do
  local device = standIn({ startSeq = 4294967295 })
  local tpap = transport()
  local first = tpap:request({ method = "get_device_info" })
  local second = tpap:request({ method = "get_energy_usage" })
  local a, b = settle(first), settle(second)
  T.eq("the first answer", Select(a, "resolved", "result", "method"), "get_device_info")
  T.eq("the second answer", Select(b, "resolved", "result", "method"), "get_energy_usage")
  T.eq("sent one at a time, from the device's sequence number, wrapping", device.requests, {
    { seq = 4294967295, method = "get_device_info" },
    { seq = 0, method = "get_energy_usage" },
  })
  T.truthy("connected", tpap:isConnected())
end

---------------------------------------------------------------------------
T.section("a session the device ends is logged in again once, after a pause")
---------------------------------------------------------------------------

do
  local device = standIn()
  local tpap = transport()
  settle(tpap:request({ method = "get_device_info" }))
  device.loseSession = true
  local outcome = settle(tpap:request({ method = "get_device_info" }))
  T.eq("answered after a new login", Select(outcome, "resolved", "error_code"), 0)
  T.eq("two sessions", device.sessions, 2)
end

---------------------------------------------------------------------------
T.section("a refused password is not tried again until the credentials change")
---------------------------------------------------------------------------

do
  local device = standIn({ password = "the real one" })
  local tpap = transport("a wrong one")
  local outcome = settle(tpap:request({ method = "get_device_info" }))
  T.truthy("refused", Select(outcome, "rejected", "refused"))
  T.eq(
    "the reason, with the tries left",
    Select(outcome, "rejected", "error"),
    "TPAP: the TP-Link account password was refused (14 tries left before the device locks);"
      .. " change TP-Link Password to try again"
  )
  local posts = device.posts
  local again = settle(tpap:request({ method = "get_device_info" }))
  T.truthy("refused again", Select(again, "rejected", "refused"))
  T.eq("without asking the device", device.posts, posts)
  T.eq("one failure counted on the device", device.failures, 1)
  tpap:configure({ password = "the real one" })
  T.eq("a new password logs in", Select(settle(tpap:request({ method = "x" })), "resolved", "error_code"), 0)
end

---------------------------------------------------------------------------
T.section("a locked device is waited out")
---------------------------------------------------------------------------

do
  local device = standIn()
  device.locked = 30
  local tpap = transport()
  local outcome = settle(tpap:request({ method = "get_device_info" }))
  T.eq("locked for its minutes", Select(outcome, "rejected", "locked"), 30)
  local posts = device.posts
  now = now + 29 * 60 * 1000
  T.eq("still locked: no login", Select(settle(tpap:connect()), "rejected", "locked"), 1)
  T.eq("without asking the device", device.posts, posts)
  device.locked = nil
  now = now + 2 * 60 * 1000
  T.eq("after the lock: a login", Select(settle(tpap:request({ method = "x" })), "resolved", "error_code"), 0)
end

---------------------------------------------------------------------------
T.section("a password scheme the transport does not know spends no try")
---------------------------------------------------------------------------

do
  local device = standIn({ extraCrypt = { type = "password_shadow", params = { passwd_id = 5 } } })
  local outcome = settle(transport():connect())
  T.truthy("not supported", Select(outcome, "rejected", "unsupported"))
  T.eq("and no share sent", device.failures, 0)
end

do
  local device = standIn({ extraCrypt = { type = "password_shadow", params = { passwd_id = 4 } } })
  T.truthy("passwd_id 4: the password itself", Select(settle(transport():connect()), "resolved"))
  T.eq("logged in", device.sessions, 1)
end

---------------------------------------------------------------------------
T.section("a device whose confirmation does not match is not trusted")
---------------------------------------------------------------------------

do
  standIn({ badConfirm = true })
  local outcome = settle(transport():connect())
  T.eq("refused", Select(outcome, "rejected", "error"), "TPAP: the device's confirmation did not match")
end

---------------------------------------------------------------------------
T.section("without lua-openssl the transport refuses before asking the device")
---------------------------------------------------------------------------

do
  local device = standIn()
  crypto.spake2plus.is_accelerated = function()
    return false, "the lua-openssl binding is not available on this host"
  end
  local outcome = settle(transport():connect())
  T.eq(
    "the reason",
    Select(outcome, "rejected", "error"),
    "TPAP needs Control4 OS 3.4.1 or later (the lua-openssl binding is not available on this host)"
  )
  T.eq("and no login sent", device.posts, nil)
  crypto.spake2plus.is_accelerated = accelerated
end

T.finish()
