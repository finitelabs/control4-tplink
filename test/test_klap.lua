--- Tests for lib.klap (v1/v2 hashing + handshake + encrypted requests) and
--- lib.smart over a real KLAP session.
---
--- Run with: ./run_test.sh test_klap.lua
---
--- Most tests run against an in-process fake KLAP device that independently
--- implements the protocol per the python-kasa reference. Optionally probes a
--- real device on the network when these environment variables are set:
---   TPLINK_TEST_IP, TPLINK_TEST_USERNAME, TPLINK_TEST_PASSWORD

require("lib.utils")
require("drivers-common-public.global.lib")

local Klap = require("lib.klap")
local Smart = require("lib.smart")

if C4:Hash("SHA256", "", { return_encoding = "NONE", data_encoding = "NONE" }) == nil then
  print("SKIP: no crypto backend in shim (run under LuaJIT with CommonCrypto/libcrypto)")
  os.exit(0)
end

local failures = 0

local function check(name, condition, detail)
  if condition then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
  end
end

local function toHex(s)
  return (s:gsub(".", function(c)
    return string.format("%02X", c:byte())
  end))
end

--- Collects a deferred's outcome (urlDo in the shim is synchronous).
local function settle(d)
  local outcome = {}
  d:next(function(value)
    outcome.resolved = value
  end, function(err)
    outcome.rejected = err
  end)
  return outcome
end

local USERNAME = "user@example.com"
local PASSWORD = "secretpassword"

---------------------------------------------------------------------------
-- Auth hash vectors (reference values computed with python hashlib)
---------------------------------------------------------------------------

local klapV2 = Klap:new()
local klapV1 = Klap:new({ authVersion = 1 })
klapV2:configure({ ip = "127.0.0.1", username = USERNAME, password = PASSWORD })
klapV1:configure({ ip = "127.0.0.1", username = USERNAME, password = PASSWORD })

check(
  "v1 auth hash matches MD5(MD5(u)..MD5(p))",
  toHex(klapV1:_authHash()) == "EC26837EFABDFBD326B59CE26ABCC57A",
  toHex(klapV1:_authHash())
)
check(
  "v2 auth hash matches SHA256(SHA1(u)..SHA1(p))",
  toHex(klapV2:_authHash()) == "15C96F9042424A517400BFEAD8B54D424688185D483DCBF07F84DE7485FA3F89",
  toHex(klapV2:_authHash())
)

---------------------------------------------------------------------------
-- Fake KLAP device
-- Independent implementation of the KLAP server side (seeds, hashes, session
-- keys, AES) following the python-kasa reference, NOT lib/klap.lua.
---------------------------------------------------------------------------

local RAW = { return_encoding = "NONE", data_encoding = "NONE" }
local AES =
  { return_encoding = "NONE", key_encoding = "NONE", iv_encoding = "NONE", data_encoding = "NONE", padding = true }

local function sha256(data)
  return C4:Hash("SHA256", data, RAW)
end

local function packInt32BE(n)
  n = n % 4294967296
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function unpackInt32BE(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  local n = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  if n >= 2147483648 then
    n = n - 4294967296
  end
  return n
end

--- @param opts { version: number, handler: fun(request: table): table }
local function fakeDevice(opts)
  local device = {
    version = opts.version,
    handler = opts.handler,
    authHash = nil,
    localSeed = nil,
    remoteSeed = "REMOTE-SEED-0123", -- 16 bytes
    key = nil,
    iv12 = nil,
    seq = nil,
    sig = nil,
    handshake2Done = false,
    requestCount = 0,
  }

  if device.version == 1 then
    local md5 = function(data)
      return C4:Hash("MD5", data, RAW)
    end
    device.authHash = md5(md5(USERNAME) .. md5(PASSWORD))
  else
    local sha1 = function(data)
      return C4:Hash("SHA1", data, RAW)
    end
    device.authHash = sha256(sha1(USERNAME) .. sha1(PASSWORD))
  end

  --- Serves one HTTP request; returns code, headers, body.
  function device:serve(url, body)
    local path = string.match(url, "^https?://[^/]+(/[^?]*)")
    local seqParam = tonumber(string.match(url, "seq=(-?%d+)") or "")

    if path == "/app/handshake1" then
      self.localSeed = body
      local serverHash
      if self.version == 1 then
        serverHash = sha256(self.localSeed .. self.authHash)
      else
        serverHash = sha256(self.localSeed .. self.remoteSeed .. self.authHash)
      end
      return 200, { ["set-cookie"] = "TP_SESSIONID=FAKESESSION;TIMEOUT=86400" }, self.remoteSeed .. serverHash
    end

    if path == "/app/handshake2" then
      local expected
      if self.version == 1 then
        expected = sha256(self.remoteSeed .. self.authHash)
      else
        expected = sha256(self.remoteSeed .. self.localSeed .. self.authHash)
      end
      if body ~= expected then
        return 403, {}, ""
      end
      local seeds = self.localSeed .. self.remoteSeed .. self.authHash
      self.key = string.sub(sha256("lsk" .. seeds), 1, 16)
      local ivFull = sha256("iv" .. seeds)
      self.iv12 = string.sub(ivFull, 1, 12)
      self.seq = unpackInt32BE(string.sub(ivFull, 29, 32))
      self.sig = string.sub(sha256("ldk" .. seeds), 1, 28)
      self.handshake2Done = true
      return 200, {}, ""
    end

    if path == "/app/request" then
      if not self.handshake2Done then
        return 403, {}, ""
      end
      self.seq = self.seq + 1
      if seqParam ~= self.seq then
        return 403, {}, ""
      end
      local signature = string.sub(body, 1, 32)
      local ciphertext = string.sub(body, 33)
      if signature ~= sha256(self.sig .. packInt32BE(self.seq) .. ciphertext) then
        return 403, {}, ""
      end
      local iv = self.iv12 .. packInt32BE(self.seq)
      local plaintext = C4:Decrypt("AES-128-CBC", self.key, iv, ciphertext, AES)
      local request = JSON:decode(plaintext)
      self.requestCount = self.requestCount + 1
      local response = JSON:encode(self.handler(request))
      local responseCipher = C4:Encrypt("AES-128-CBC", self.key, iv, response, AES)
      local responseSignature = sha256(self.sig .. packInt32BE(self.seq) .. responseCipher)
      return 200, {}, responseSignature .. responseCipher
    end

    return 404, {}, ""
  end

  --- Installs this device as the global urlDo.
  function device:install()
    function urlDo(method, url, data, headers, callback, context, options)
      local code, responseHeaders, responseBody = device:serve(url, data or "")
      if code >= 200 and code < 300 then
        callback(nil, code, responseHeaders, responseBody, nil, url)
      else
        callback("HTTP " .. code, code, responseHeaders, responseBody, nil, url)
      end
    end
  end

  return device
end

---------------------------------------------------------------------------
-- v2 handshake + IOT request round-trip
---------------------------------------------------------------------------

local iotSysinfo = { system = { get_sysinfo = { err_code = 0, model = "HS300(US)", relay_state = 1 } } }

local deviceV2 = fakeDevice({
  version = 2,
  handler = function(request)
    if Select(request, "system", "get_sysinfo") then
      return iotSysinfo
    end
    return { system = { err_code = -1 } }
  end,
})
deviceV2:install()

local klap = Klap:new()
klap:configure({ ip = "127.0.0.1", username = USERNAME, password = PASSWORD })

local outcome = settle(klap:connect())
check("v2 handshake succeeds", outcome.resolved ~= nil, Select(outcome.rejected, "error"))

outcome = settle(klap:request({ system = { get_sysinfo = {} } }))
check(
  "v2 request round-trips",
  Select(outcome.resolved, "system", "get_sysinfo", "model") == "HS300(US)",
  Select(outcome.rejected, "error")
)

outcome = settle(klap:request({ system = { get_sysinfo = {} } }))
check("v2 second request advances seq", Select(outcome.resolved, "system", "get_sysinfo", "err_code") == 0)
check("v2 device saw both requests", deviceV2.requestCount == 2, deviceV2.requestCount)

---------------------------------------------------------------------------
-- v1 handshake + IOT request round-trip
---------------------------------------------------------------------------

local deviceV1 = fakeDevice({
  version = 1,
  handler = function(request)
    if Select(request, "system", "get_sysinfo") then
      return { system = { get_sysinfo = { err_code = 0, model = "KP115(US)", relay_state = 0 } } }
    end
    return { system = { err_code = -1 } }
  end,
})
deviceV1:install()

local klap1 = Klap:new({ authVersion = 1 })
klap1:configure({ ip = "127.0.0.1", username = USERNAME, password = PASSWORD })

outcome = settle(klap1:connect())
check("v1 handshake succeeds", outcome.resolved ~= nil, Select(outcome.rejected, "error"))

outcome = settle(klap1:request({ system = { get_sysinfo = {} } }))
check(
  "v1 request round-trips",
  Select(outcome.resolved, "system", "get_sysinfo", "model") == "KP115(US)",
  Select(outcome.rejected, "error")
)

---------------------------------------------------------------------------
-- Hash version mismatches
---------------------------------------------------------------------------

-- v2 client against v1 device: server hash cannot match.
deviceV1:install()
local klapWrongVersion = Klap:new()
klapWrongVersion:configure({ ip = "127.0.0.1", username = USERNAME, password = PASSWORD })
outcome = settle(klapWrongVersion:connect())
check(
  "v2 client vs v1 device reports auth mismatch",
  string.find(tostring(Select(outcome.rejected, "error")), "auth mismatch", 1, true) ~= nil,
  Select(outcome.rejected, "error")
)

-- Correct version, wrong password.
deviceV2:install()
local klapWrongPassword = Klap:new()
klapWrongPassword:configure({ ip = "127.0.0.1", username = USERNAME, password = "wrong" })
outcome = settle(klapWrongPassword:connect())
check(
  "wrong password reports auth mismatch",
  string.find(tostring(Select(outcome.rejected, "error")), "auth mismatch", 1, true) ~= nil,
  Select(outcome.rejected, "error")
)

---------------------------------------------------------------------------
-- SMART schema over a real KLAP session (fake EP25)
---------------------------------------------------------------------------

local relayState = true
local fakeEp25 = fakeDevice({
  version = 2,
  handler = function(request)
    local method = Select(request, "method")
    if method == "get_device_info" then
      return {
        error_code = 0,
        result = {
          model = "EP25",
          nickname = C4:Base64Encode("Fountain Pump"),
          fw_ver = "1.0.3 Build 240621",
          hw_ver = "2.6",
          mac = "AC-15-A2-00-00-00",
          rssi = -48,
          device_on = relayState,
        },
      }
    elseif method == "set_device_info" then
      relayState = Select(request, "params", "device_on") == true
      return { error_code = 0 }
    elseif method == "get_energy_usage" then
      return { error_code = 0, result = { current_power = 2750, today_energy = 12 } }
    end
    return { error_code = -10008 }
  end,
})
fakeEp25:install()

local klapSmart = Klap:new()
klapSmart:configure({ ip = "127.0.0.1", username = USERNAME, password = PASSWORD })
local smart = Smart:new(klapSmart)

outcome = settle(smart:request({ system = { get_sysinfo = {} } }))
local sysinfo = Select(outcome.resolved, "system", "get_sysinfo")
check("EP25 sysinfo over KLAP", Select(sysinfo, "err_code") == 0, Select(outcome.rejected, "error"))
check("EP25 model mapped", Select(sysinfo, "model") == "EP25")
check("EP25 alias decoded", Select(sysinfo, "alias") == "Fountain Pump")
check("EP25 relay_state mapped", Select(sysinfo, "relay_state") == 1)

outcome = settle(smart:request({ system = { set_relay_state = { state = 0 } } }))
check("EP25 relay off accepted", Select(outcome.resolved, "system", "set_relay_state", "err_code") == 0)
check("EP25 relay actually off", relayState == false)

outcome = settle(smart:request({ system = { get_sysinfo = {} } }))
check("EP25 sysinfo reflects off", Select(outcome.resolved, "system", "get_sysinfo", "relay_state") == 0)

outcome = settle(smart:request({ emeter = { get_realtime = {} } }))
check("EP25 energy mapped to power_mw", Select(outcome.resolved, "emeter", "get_realtime", "power_mw") == 2750)

---------------------------------------------------------------------------
-- Optional: probe a real device on the network
---------------------------------------------------------------------------

local realIp = os.getenv("TPLINK_TEST_IP")
if realIp ~= nil and realIp ~= "" then
  -- Restore the shim's real HTTP urlDo (the fakes replaced it).
  urlDo = nil
  dofile("c4_shim.lua")
  assert(urlDo ~= nil, "real-device probe requires luasocket in the shim")

  print("")
  print("Probing real device at " .. realIp .. "...")

  local realKlap = Klap:new()
  realKlap:configure({
    ip = realIp,
    username = os.getenv("TPLINK_TEST_USERNAME") or "",
    password = os.getenv("TPLINK_TEST_PASSWORD") or "",
  })
  local realSmart = Smart:new(realKlap)

  outcome = settle(realSmart:request({ system = { get_sysinfo = {} } }))
  sysinfo = Select(outcome.resolved, "system", "get_sysinfo")
  if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
    print(
      string.format(
        "REAL DEVICE (SMART): model=%s fw=%s hw=%s alias=%s rssi=%s relay=%s",
        tostring(sysinfo.model),
        tostring(sysinfo.sw_ver),
        tostring(sysinfo.hw_ver),
        tostring(sysinfo.alias),
        tostring(sysinfo.rssi),
        tostring(sysinfo.relay_state)
      )
    )
  else
    print("SMART probe did not succeed; trying IOT schema over KLAP...")
    outcome = settle(realKlap:request({ system = { get_sysinfo = {} } }))
    sysinfo = Select(outcome.resolved, "system", "get_sysinfo")
    if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
      print(
        string.format(
          "REAL DEVICE (KLAP/IOT): model=%s fw=%s alias=%s",
          tostring(sysinfo.model),
          tostring(sysinfo.sw_ver),
          tostring(sysinfo.alias)
        )
      )
    else
      print("REAL DEVICE: no response on either schema: " .. tostring(Select(outcome.rejected, "error")))
    end
  end
end

---------------------------------------------------------------------------

print("")
if failures > 0 then
  error(failures .. " test(s) failed")
end
print("All tests passed")
