--- Tests for tplink.legacy: the port 9999 transport, one request at a time.
---
--- Run with: ./run_test.sh test_legacy.lua

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")

local bit = require("bit")
local Legacy = require("tplink.legacy")

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

T.section("A request the device never answers")
do
  ShimResetSentFrames()
  local lost = settle(legacy:request(SYSINFO))
  local waiting = settle(legacy:request(SYSINFO))
  T.eq("one goes out", #ShimSentFrames(), 1)
  ShimFireTimers()
  T.eq("it times out", Select(lost.rejected, "error"), "Legacy: request timed out (no response on UDP 9999)")
  T.eq("and the next goes out", #ShimSentFrames(), 2)
  T.eq("which still waits for its answer", waiting, {})
  datagram(JSON:encode({ system = { get_sysinfo = { err_code = 0 } } }))
  T.eq("and gets it", Select(waiting.resolved, "system", "get_sysinfo", "err_code"), 0)
end

T.section("No address to send to")
do
  ShimResetSentFrames()
  local unset = Legacy:new()
  local one = settle(unset:request(SYSINFO))
  local two = settle(unset:request(SYSINFO))
  T.eq("each request fails", {
    Select(one.rejected, "error"),
    Select(two.rejected, "error"),
  }, { "Legacy: no IP address configured", "Legacy: no IP address configured" })
  T.eq("and nothing goes out", #ShimSentFrames(), 0)
end

T.finish()
