--- Unit tests for lib.iotbulb: IOT bulb schema -> light entity/state mapping.
---
--- Run with: ./run_test.sh test_iotbulb.lua

require("lib.utils")
require("drivers-common-public.global.lib")

local deferred = require("deferred")
local constants = require("constants")
local IotBulb = require("lib.iotbulb")

local ColorMode = constants.LightColorMode

--- Fake transport: records requests, replays queued responses.
local FakeTransport = {}
FakeTransport.__index = FakeTransport

function FakeTransport:new()
  return setmetatable({ requests = {}, responses = {} }, self)
end

function FakeTransport:reply(response)
  table.insert(self.responses, response)
end

function FakeTransport:request(payload)
  table.insert(self.requests, payload)
  local d = deferred.new()
  local reply = table.remove(self.responses, 1)
  assert(reply ~= nil, "FakeTransport: no reply queued for request")
  if reply.reject then
    d:reject(reply.reject)
  else
    d:resolve(reply.resolve)
  end
  return d
end

--- Collects a deferred's synchronous outcome.
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

local function approx(a, b)
  return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.001
end

--- Builds a KL-style sysinfo response.
local function sysinfoReply(fields)
  local sysinfo = { err_code = 0 }
  for k, v in pairs(fields) do
    sysinfo[k] = v
  end
  return { resolve = { system = { get_sysinfo = sysinfo } } }
end

local LIGHT_SERVICE = "smartlife.iot.smartbulb.lightingservice"

---------------------------------------------------------------------------
-- poll(): entity synthesis
---------------------------------------------------------------------------

local transport = FakeTransport:new()
local bulb = IotBulb:new(transport)

transport:reply(sysinfoReply({
  model = "KL130(US)",
  is_dimmable = 1,
  is_color = 1,
  is_variable_color_temp = 1,
  light_state = { on_off = 1, mode = "normal", hue = 120, saturation = 75, color_temp = 0, brightness = 80 },
}))
local outcome = settle(bulb:poll())
local result = outcome.resolved
check("poll sends get_sysinfo", Select(transport.requests[1], "system", "get_sysinfo") ~= nil)
check("KL130 resolves", result ~= nil, Select(outcome.rejected, "error"))
check(
  "KL130 mode is RGB+CCT",
  Select(result, "entity", "supported_color_modes", 1) == ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE
)
check("KL130 min mireds from 9000K", approx(Select(result, "entity", "min_mireds"), 1e6 / 9000))
check("KL130 max mireds from 2500K", approx(Select(result, "entity", "max_mireds"), 1e6 / 2500))

---------------------------------------------------------------------------
-- poll(): state synthesis
---------------------------------------------------------------------------

local state = Select(result, "state")
check("on bulb reports state=true", Select(state, "state") == true)
check("brightness scales to 0-1", approx(Select(state, "brightness"), 0.8))
check("hue/sat maps to RGB mode", Select(state, "color_mode") == ColorMode.COLOR_MODE_RGB)
check("hsv(120,75) green channel", approx(Select(state, "green"), 1.0))
check("hsv(120,75) red channel", approx(Select(state, "red"), 0.25))

-- Off bulb: values come from dft_on_state (per the KL130 fixture shape).
transport:reply(sysinfoReply({
  model = "KL130(US)",
  is_dimmable = 1,
  is_color = 1,
  is_variable_color_temp = 1,
  light_state = {
    on_off = 0,
    dft_on_state = { brightness = 30, color_temp = 0, hue = 240, mode = "normal", saturation = 100 },
  },
}))
state = Select(settle(bulb:poll()).resolved, "state")
check("off bulb reports state=false", Select(state, "state") == false)
check("off bulb reads dft_on_state brightness", approx(Select(state, "brightness"), 0.3))
check("off bulb reads dft_on_state color", approx(Select(state, "blue"), 1.0))

-- Color temperature mode.
transport:reply(sysinfoReply({
  model = "KL130(US)",
  is_dimmable = 1,
  is_color = 1,
  is_variable_color_temp = 1,
  light_state = { on_off = 1, color_temp = 3000, brightness = 50 },
}))
state = Select(settle(bulb:poll()).resolved, "state")
check("color_temp maps to CCT mode", Select(state, "color_mode") == ColorMode.COLOR_MODE_COLOR_TEMPERATURE)
check("color_temp converts to mireds", approx(Select(state, "color_temperature"), 1e6 / 3000))

---------------------------------------------------------------------------
-- poll(): capability and model variants
---------------------------------------------------------------------------

local cctBulb = IotBulb:new(transport)
transport:reply(sysinfoReply({
  model = "KL120(US)",
  is_dimmable = 1,
  is_color = 0,
  is_variable_color_temp = 1,
  light_state = { on_off = 1, color_temp = 3500, brightness = 100 },
}))
result = settle(cctBulb:poll()).resolved
check(
  "CCT-only bulb mode",
  Select(result, "entity", "supported_color_modes", 1) == ColorMode.COLOR_MODE_COLOR_TEMPERATURE
)
check("KL120(US) kelvin range low", approx(Select(result, "entity", "min_mireds"), 1e6 / 5000))
check("KL120(US) kelvin range high", approx(Select(result, "entity", "max_mireds"), 1e6 / 2700))

local dimBulb = IotBulb:new(transport)
transport:reply(sysinfoReply({
  model = "LB100(US)",
  is_dimmable = 1,
  is_color = 0,
  is_variable_color_temp = 0,
  light_state = { on_off = 0, dft_on_state = { brightness = 50 } },
}))
result = settle(dimBulb:poll()).resolved
check(
  "dimmable-only bulb mode",
  Select(result, "entity", "supported_color_modes", 1) == ColorMode.COLOR_MODE_BRIGHTNESS
)
check("dimmable-only bulb has no mireds", Select(result, "entity", "min_mireds") == nil)

local unknownBulb = IotBulb:new(transport)
transport:reply(sysinfoReply({
  model = "KL999(XX)",
  is_dimmable = 1,
  is_color = 0,
  is_variable_color_temp = 1,
  light_state = { on_off = 1, color_temp = 3000 },
}))
result = settle(unknownBulb:poll()).resolved
check("unknown model falls back to 2700-5000", approx(Select(result, "entity", "min_mireds"), 1e6 / 5000))

---------------------------------------------------------------------------
-- poll(): rejections
---------------------------------------------------------------------------

transport:reply(sysinfoReply({ model = "KP115(US)", relay_state = 1 }))
outcome = settle(bulb:poll())
check(
  "non-light device rejects",
  string.find(tostring(Select(outcome.rejected, "error")), "not an IOT%-schema light") ~= nil,
  Select(outcome.rejected, "error")
)

transport:reply({ resolve = { system = { get_sysinfo = { err_code = -1 } } } })
outcome = settle(bulb:poll())
check("sysinfo error rejects", Select(outcome.rejected, "error") ~= nil)

transport:reply({ reject = { error = "Legacy: request timed out" } })
outcome = settle(bulb:poll())
check("transport failure propagates", Select(outcome.rejected, "error") ~= nil)

---------------------------------------------------------------------------
-- execute(): command translation
---------------------------------------------------------------------------

-- Re-establish the KL130 kelvin range on the main test bulb.
transport:reply(sysinfoReply({
  model = "KL130(US)",
  is_dimmable = 1,
  is_color = 1,
  is_variable_color_temp = 1,
  light_state = { on_off = 1, color_temp = 2700 },
}))
settle(bulb:poll())

local function lastLightParams()
  return Select(transport.requests[#transport.requests], LIGHT_SERVICE, "transition_light_state")
end

local okReply = { resolve = { [LIGHT_SERVICE] = { transition_light_state = { err_code = 0 } } } }

transport:reply(okReply)
settle(bulb:execute({ has_state = true, state = true }))
local params = lastLightParams()
check("bare on sends on_off=1", Select(params, "on_off") == 1)
check("bare on leaves ignore_default unset", Select(params, "ignore_default") == nil)

transport:reply(okReply)
settle(bulb:execute({ has_state = true, state = false }))
check("off sends on_off=0", Select(lastLightParams(), "on_off") == 0)

transport:reply(okReply)
settle(bulb:execute({ has_state = true, state = true, has_brightness = true, brightness = 0.5 }))
params = lastLightParams()
check("brightness scales to 1-100", Select(params, "brightness") == 50)
check("brightness sets ignore_default", Select(params, "ignore_default") == 1)

transport:reply(okReply)
settle(bulb:execute({ has_state = true, state = false, has_brightness = true, brightness = 0.5 }))
check("brightness omitted when turning off", Select(lastLightParams(), "brightness") == nil)

transport:reply(okReply)
settle(bulb:execute({ has_color_temperature = true, color_temperature = 1e6 / 10000 }))
params = lastLightParams()
check("kelvin clamps to model range", Select(params, "color_temp") == 9000)

transport:reply(okReply)
settle(bulb:execute({ has_rgb = true, red = 1, green = 0, blue = 0 }))
params = lastLightParams()
check("rgb maps to hue", Select(params, "hue") == 0)
check("rgb maps to saturation", Select(params, "saturation") == 100)
check("rgb clears color_temp", Select(params, "color_temp") == 0)

transport:reply(okReply)
settle(bulb:execute({ has_state = true, state = true, has_transition_length = true, transition_length = 2500 }))
check("ramp forwards as transition_period", Select(lastLightParams(), "transition_period") == 2500)

transport:reply(okReply)
settle(bulb:execute({ has_state = true, state = true, has_transition_length = true, transition_length = 120000 }))
check("transition_period caps at 60s", Select(lastLightParams(), "transition_period") == 60000)

local requestsBefore = #transport.requests
outcome = settle(bulb:execute({}))
check("empty command is a no-op", #transport.requests == requestsBefore and outcome.resolved ~= nil)

transport:reply({ resolve = { [LIGHT_SERVICE] = { transition_light_state = { err_code = -3 } } } })
outcome = settle(bulb:execute({ has_state = true, state = true }))
check("device rejection rejects", Select(outcome.rejected, "error") ~= nil)

---------------------------------------------------------------------------
-- Light strips (KL400/KL420/KL430): different command envelope
---------------------------------------------------------------------------

local STRIP_SERVICE = "smartlife.iot.lightStrip"

local strip = IotBulb:new(transport)
transport:reply(sysinfoReply({
  model = "KL430(US)",
  is_dimmable = 1,
  is_color = 1,
  is_variable_color_temp = 1,
  length = 16,
  light_state = { on_off = 1, mode = "normal", hue = 0, saturation = 0, color_temp = 4000, brightness = 60 },
  lighting_effect_state = { enable = 0, name = "Aurora", brightness = 100 },
}))
result = settle(strip:poll()).resolved
check("KL430 polls as a light", result ~= nil)
check("KL430 kelvin range from table", approx(Select(result, "entity", "max_mireds"), 1e6 / 2500))
check("KL430 idle effect leaves brightness", approx(Select(result, "state", "brightness"), 0.6))

transport:reply({ resolve = { [STRIP_SERVICE] = { set_light_state = { err_code = 0 } } } })
outcome = settle(strip:execute({ has_state = true, state = true }))
local sent = transport.requests[#transport.requests]
check("strip commands use lightStrip module", Select(sent, STRIP_SERVICE, "set_light_state") ~= nil)
check("strip command accepted", outcome.resolved ~= nil, Select(outcome.rejected, "error"))

-- While a lighting effect runs, brightness comes from the effect state.
transport:reply(sysinfoReply({
  model = "KL430(US)",
  is_dimmable = 1,
  is_color = 1,
  is_variable_color_temp = 1,
  length = 16,
  light_state = { on_off = 1, mode = "normal", hue = 0, saturation = 0, color_temp = 0, brightness = 60 },
  lighting_effect_state = { enable = 1, name = "Aurora", brightness = 35 },
}))
result = settle(strip:poll()).resolved
check("active effect drives brightness", approx(Select(result, "state", "brightness"), 0.35))

-- A bulb instance keeps the bulb envelope regardless of strip usage.
transport:reply(okReply)
settle(bulb:execute({ has_state = true, state = true }))
check(
  "bulb still uses lightingservice module",
  Select(transport.requests[#transport.requests], LIGHT_SERVICE, "transition_light_state") ~= nil
)

---------------------------------------------------------------------------

print("")
if failures > 0 then
  error(failures .. " test(s) failed")
end
print("All tests passed")
