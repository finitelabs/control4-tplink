--- Tests for lib.legacy: the port 9999 transport, one request at a time.
---
--- Run with: ./run_test.sh test_legacy.lua

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.handlers")

local bit = require("bit")

local T = require("testlib")
local Legacy = require("lib.legacy")

--- Collects a deferred's outcome.
local function settle(d)
  local outcome = {}
  d:next(function(value)
    outcome.resolved = value
  end, function(err)
    outcome.rejected = err
  end)
  return outcome
end

--- The Kasa rolling XOR cipher, as a device scrambles what it sends.
local function scramble(plaintext)
  local key = 171
  local out = {}
  for i = 1, #plaintext do
    key = bit.bxor(key, plaintext:byte(i))
    out[i] = string.char(key)
  end
  return table.concat(out)
end

--- A datagram from the device, as Director hands it to the driver.
local function datagram(text)
  return pcall(RFN[6001], 6001, 9999, scramble(text))
end

local SYSINFO = { system = { get_sysinfo = {} } }

T.section("A datagram that cannot be read")

local legacy = Legacy:new()
legacy:configure({ ip = "192.0.2.24" })
local first = settle(legacy:request(SYSINFO))
local second = settle(legacy:request(SYSINFO))
T.eq("one request goes out, and the next waits for its answer", #ShimSentFrames(), 1)
T.check("a datagram cut short raises nothing", (datagram('{"system":{"get_sysinfo":{"err_code":0,"light_st')))
T.eq("it fails the request it answers", Select(first.rejected, "error"), "Legacy: response is not valid JSON")
T.eq("and the next goes out", #ShimSentFrames(), 2)
datagram(JSON:encode({ system = { get_sysinfo = { err_code = 0 } } }))
T.eq("whose answer is read", Select(second.resolved, "system", "get_sysinfo", "err_code"), 0)

T.finish()
