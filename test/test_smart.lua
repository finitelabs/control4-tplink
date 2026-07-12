--- Unit tests for lib.smart: IOT-schema <-> SMART-schema translation.
---
--- Run with: ./run_test.sh test_smart.lua

require("lib.utils")
require("drivers-common-public.global.lib")

local deferred = require("deferred")
local Smart = require("lib.smart")

--- Fake Klap transport: records requests, replays queued responses.
local FakeKlap = {}
FakeKlap.__index = FakeKlap

function FakeKlap:new()
  return setmetatable({ requests = {}, responses = {} }, self)
end

--- Queue a resolution (or rejection when `reject` is set) for the next request.
function FakeKlap:reply(response)
  table.insert(self.responses, response)
end

function FakeKlap:request(payload)
  table.insert(self.requests, payload)
  local d = deferred.new()
  local reply = table.remove(self.responses, 1)
  assert(reply ~= nil, "FakeKlap: no reply queued for request")
  if reply.reject then
    d:reject(reply.reject)
  else
    d:resolve(reply.resolve)
  end
  return d
end

--- Collects a deferred's synchronous outcome (zserge/deferred fires callbacks
--- immediately once settled).
local function settle(d)
  local outcome = {}
  d:next(function(value)
    outcome.resolved = value
  end, function(err)
    outcome.rejected = err
  end)
  assert(outcome.resolved ~= nil or outcome.rejected ~= nil, "deferred did not settle synchronously")
  return outcome
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

---------------------------------------------------------------------------
-- get_sysinfo -> get_device_info
---------------------------------------------------------------------------

local klap = FakeKlap:new()
local smart = Smart:new(klap)

klap:reply({
  resolve = {
    error_code = 0,
    result = {
      model = "EP25",
      nickname = C4:Base64Encode("Fountain Pump"),
      mac = "AC-15-A2-00-00-00",
      fw_ver = "1.0.3 Build 240621",
      hw_ver = "2.6",
      rssi = -52,
      device_on = true,
    },
  },
})
klap:reply({ resolve = { error_code = -10008 } }) -- child device list rejected (single outlet)
local outcome = settle(smart:request({ system = { get_sysinfo = {} } }))
local sent = klap.requests[#klap.requests - 1]
check("get_sysinfo sends get_device_info", Select(sent, "method") == "get_device_info")
check(
  "first get_sysinfo probes get_child_device_list",
  Select(klap.requests[#klap.requests], "method") == "get_child_device_list"
)
local sysinfo = Select(outcome.resolved, "system", "get_sysinfo")
check("get_sysinfo maps err_code", Select(sysinfo, "err_code") == 0)
check("get_sysinfo decodes nickname", Select(sysinfo, "alias") == "Fountain Pump", Select(sysinfo, "alias"))
check("get_sysinfo maps model", Select(sysinfo, "model") == "EP25")
check("get_sysinfo maps firmware", Select(sysinfo, "sw_ver") == "1.0.3 Build 240621")
check("get_sysinfo maps rssi", Select(sysinfo, "rssi") == -52)
check("get_sysinfo maps relay_state on", Select(sysinfo, "relay_state") == 1)

klap:reply({ resolve = { error_code = 0, result = { model = "EP25", device_on = false } } })
outcome = settle(smart:request({ system = { get_sysinfo = {} } }))
sysinfo = Select(outcome.resolved, "system", "get_sysinfo")
check("get_sysinfo maps relay_state off", Select(sysinfo, "relay_state") == 0)
check("get_sysinfo tolerates missing nickname", Select(sysinfo, "alias") == nil)

klap:reply({ resolve = { error_code = -1501 } })
outcome = settle(smart:request({ system = { get_sysinfo = {} } }))
check("get_sysinfo maps SMART error", Select(outcome.resolved, "system", "get_sysinfo", "err_code") == -1501)

klap:reply({ reject = { error = "Klap: request failed", code = 500 } })
outcome = settle(smart:request({ system = { get_sysinfo = {} } }))
check("get_sysinfo propagates transport failure", Select(outcome.rejected, "error") ~= nil)

---------------------------------------------------------------------------
-- set_relay_state -> set_device_info
---------------------------------------------------------------------------

klap:reply({ resolve = { error_code = 0 } })
outcome = settle(smart:request({ system = { set_relay_state = { state = 1 } } }))
sent = klap.requests[#klap.requests]
check("set_relay_state sends set_device_info", Select(sent, "method") == "set_device_info")
check("set_relay_state on maps device_on=true", Select(sent, "params", "device_on") == true)
check("set_relay_state maps ok", Select(outcome.resolved, "system", "set_relay_state", "err_code") == 0)

klap:reply({ resolve = { error_code = 0 } })
settle(smart:request({ system = { set_relay_state = { state = 0 } } }))
sent = klap.requests[#klap.requests]
check("set_relay_state off maps device_on=false", Select(sent, "params", "device_on") == false)

klap:reply({ resolve = { error_code = 9999 } })
outcome = settle(smart:request({ system = { set_relay_state = { state = 1 } } }))
check("set_relay_state maps SMART error", Select(outcome.resolved, "system", "set_relay_state", "err_code") == 9999)

---------------------------------------------------------------------------
-- emeter.get_realtime -> get_energy_usage
---------------------------------------------------------------------------

klap:reply({ resolve = { error_code = 0, result = { current_power = 3251, today_energy = 274 } } })
outcome = settle(smart:request({ emeter = { get_realtime = {} } }))
sent = klap.requests[#klap.requests]
check("get_realtime sends get_energy_usage", Select(sent, "method") == "get_energy_usage")
local realtime = Select(outcome.resolved, "emeter", "get_realtime")
check("get_realtime maps ok", Select(realtime, "err_code") == 0)
check("get_realtime maps current_power to power_mw", Select(realtime, "power_mw") == 3251)

klap:reply({ resolve = { error_code = -10008 } })
outcome = settle(smart:request({ emeter = { get_realtime = {} } }))
check(
  "get_realtime maps missing energy monitoring to err_code",
  Select(outcome.resolved, "emeter", "get_realtime", "err_code") == -10008
)

---------------------------------------------------------------------------
-- Children: single-outlet devices cache the rejected probe
---------------------------------------------------------------------------

-- The first get_sysinfo on a fresh adapter probes get_child_device_list.
local single = Smart:new(klap)
klap:reply({ resolve = { error_code = 0, result = { model = "EP25", device_on = true } } })
klap:reply({ resolve = { error_code = -10008 } }) -- child list rejected
outcome = settle(single:request({ system = { get_sysinfo = {} } }))
sysinfo = Select(outcome.resolved, "system", "get_sysinfo")
check("single-outlet sysinfo ok despite child probe rejection", Select(sysinfo, "err_code") == 0)
check("single-outlet has no children", Select(sysinfo, "children") == nil)

local requestsBefore = #klap.requests
klap:reply({ resolve = { error_code = 0, result = { model = "EP25", device_on = true } } })
outcome = settle(single:request({ system = { get_sysinfo = {} } }))
check("single-outlet child probe not repeated", #klap.requests == requestsBefore + 1)
check("single-outlet second sysinfo ok", Select(outcome.resolved, "system", "get_sysinfo", "err_code") == 0)

---------------------------------------------------------------------------
-- Children: multi-outlet devices (SMART power strips)
---------------------------------------------------------------------------

local strip = Smart:new(klap)
klap:reply({ resolve = { error_code = 0, result = { model = "P300" } } })
klap:reply({
  resolve = {
    error_code = 0,
    result = {
      start_index = 0,
      sum = 3,
      child_device_list = {
        { device_id = "child-1", nickname = C4:Base64Encode("Left"), device_on = true },
        { device_id = "child-2", nickname = C4:Base64Encode("Middle"), device_on = false },
      },
    },
  },
})
klap:reply({
  resolve = {
    error_code = 0,
    result = {
      start_index = 2,
      sum = 3,
      child_device_list = {
        { device_id = "child-3", nickname = C4:Base64Encode("Right"), device_on = true },
      },
    },
  },
})
outcome = settle(strip:request({ system = { get_sysinfo = {} } }))
sysinfo = Select(outcome.resolved, "system", "get_sysinfo")
local children = Select(sysinfo, "children")
check("strip sysinfo ok", Select(sysinfo, "err_code") == 0, Select(outcome.rejected, "error"))
check("strip children paginated", type(children) == "table" and #children == 3)
check("strip child id mapped", Select(children, 1, "id") == "child-1")
check("strip child alias decoded", Select(children, 2, "alias") == "Middle")
check("strip child state on", Select(children, 1, "state") == 1)
check("strip child state off", Select(children, 2, "state") == 0)
check("strip pagination requested next page", Select(klap.requests[#klap.requests], "params", "start_index") == 2)

-- A known strip whose child fetch fails must surface the error, not silently
-- collapse to a single output.
klap:reply({ resolve = { error_code = 0, result = { model = "P300" } } })
klap:reply({ reject = { error = "Klap: request failed", code = 500 } })
outcome = settle(strip:request({ system = { get_sysinfo = {} } }))
check("strip child fetch failure surfaces err_code", Select(outcome.resolved, "system", "get_sysinfo", "err_code") ~= 0)

---------------------------------------------------------------------------
-- Children: control via control_child
---------------------------------------------------------------------------

klap:reply({
  resolve = {
    error_code = 0,
    result = { responseData = { result = { responses = { { method = "set_device_info", error_code = 0 } } } } },
  },
})
outcome = settle(strip:request({
  context = { child_ids = { "child-2" } },
  system = { set_relay_state = { state = 1 } },
}))
sent = klap.requests[#klap.requests]
check("child relay uses control_child", Select(sent, "method") == "control_child")
check("child relay targets device_id", Select(sent, "params", "device_id") == "child-2")
check("child relay nests multipleRequest", Select(sent, "params", "requestData", "method") == "multipleRequest")
local nested = Select(sent, "params", "requestData", "params", "requests", 1)
check("child relay nests set_device_info", Select(nested, "method") == "set_device_info")
check("child relay maps device_on", Select(nested, "params", "device_on") == true)
check("child relay ok mapped", Select(outcome.resolved, "system", "set_relay_state", "err_code") == 0)

klap:reply({
  resolve = {
    error_code = 0,
    result = { responseData = { result = { responses = { { method = "set_device_info", error_code = -1501 } } } } },
  },
})
outcome = settle(strip:request({
  context = { child_ids = { "child-2" } },
  system = { set_relay_state = { state = 0 } },
}))
check("child relay inner error mapped", Select(outcome.resolved, "system", "set_relay_state", "err_code") == -1501)

klap:reply({
  resolve = {
    error_code = 0,
    result = {
      responseData = {
        result = {
          responses = { { method = "get_energy_usage", error_code = 0, result = { current_power = 512 } } },
        },
      },
    },
  },
})
outcome = settle(strip:request({
  context = { child_ids = { "child-3" } },
  emeter = { get_realtime = {} },
}))
sent = klap.requests[#klap.requests]
nested = Select(sent, "params", "requestData", "params", "requests", 1)
check("child energy nests get_energy_usage", Select(nested, "method") == "get_energy_usage")
check("child energy omits empty params", Select(nested, "params") == nil)
check("child energy maps power_mw", Select(outcome.resolved, "emeter", "get_realtime", "power_mw") == 512)

---------------------------------------------------------------------------
-- Unsupported requests
---------------------------------------------------------------------------

outcome = settle(smart:request({ system = { set_led_off = { off = 1 } } }))
check("unknown requests are rejected", Select(outcome.rejected, "error") ~= nil)

---------------------------------------------------------------------------

print("")
if failures > 0 then
  error(failures .. " test(s) failed")
end
print("All tests passed")
