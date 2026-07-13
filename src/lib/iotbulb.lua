--- IOT-schema adapter for legacy TP-Link Kasa bulbs and light strips
--- (KL/LB series).
---
--- Kasa's original bulbs speak the legacy IOT JSON schema: capabilities and
--- the current `light_state` come from `system.get_sysinfo`, and light changes
--- go through `smartlife.iot.smartbulb.lightingservice.transition_light_state`
--- (per the python-kasa reference). Light strips (KL400/KL420/KL430) take the
--- same parameters through `smartlife.iot.lightStrip.set_light_state`; a
--- `length` field in sysinfo marks a strip. The schema is transport-agnostic —
--- devices on original firmware answer over the legacy port 9999 transport,
--- devices on post-2024 firmware answer over KLAP — so this adapter takes any
--- transport exposing `request(payload)` and maps the schema to the entity/
--- state/command shapes the light driver's direct mode uses:
---
---   poll()       -> { entity, state }  (applyUpdate shapes)
---   execute(opts)-> transition_light_state / set_light_state
---                   (light_command shape in)

local deferred = require("deferred")

local log = require("lib.logging")
local constants = require("constants")

local ColorMode = constants.LightColorMode

--- The IOT module and method that set bulb light state.
local BULB_SERVICE = "smartlife.iot.smartbulb.lightingservice"
local BULB_SET_METHOD = "transition_light_state"

--- The IOT module and method that set light strip state.
local STRIP_SERVICE = "smartlife.iot.lightStrip"
local STRIP_SET_METHOD = "set_light_state"

--- Firmware caps device-side transitions at 60 seconds.
local MAX_TRANSITION_MS = 60000

--- Kelvin ranges by model (sysinfo does not report them); per the python-kasa
--- reference, with its 2700-5000 fallback for unlisted models.
local KELVIN_RANGES = {
  { pattern = "LB130", min = 2500, max = 9000 },
  { pattern = "LB230", min = 2500, max = 9000 },
  { pattern = "KB130", min = 2500, max = 9000 },
  { pattern = "KL130", min = 2500, max = 9000 },
  { pattern = "KL135", min = 2500, max = 9000 },
  { pattern = "KL430", min = 2500, max = 9000 },
  { pattern = "LB120", min = 2700, max = 6500 },
  { pattern = "KL125", min = 2500, max = 6500 },
  { pattern = "KL120%(EU%)", min = 2700, max = 6500 },
  { pattern = "KL120%(US%)", min = 2700, max = 5000 },
}

--- @class IotBulb
--- @field _transport Legacy|Klap The transport to the device (owned by the driver).
--- @field _kelvinMin number Lower bound of the color temperature range.
--- @field _kelvinMax number Upper bound of the color temperature range.
--- @field _isStrip boolean Whether the device is a light strip (set by poll).
local IotBulb = {}
IotBulb.__index = IotBulb

--- Creates a new IOT bulb adapter over an existing transport.
--- The transport's configuration and lifecycle stay with its owner.
--- @param transport Legacy|Klap
--- @return IotBulb
function IotBulb:new(transport)
  log:trace("IotBulb:new()")
  local instance = setmetatable({}, self)
  instance._transport = transport
  instance._kelvinMin = 2700
  instance._kelvinMax = 5000
  instance._isStrip = false
  return instance
end

--- Looks up the kelvin range for a model string (e.g. "KL130(US)").
--- @param model any
--- @return number kelvinMin
--- @return number kelvinMax
local function kelvinRangeForModel(model)
  if type(model) == "string" then
    for _, range in ipairs(KELVIN_RANGES) do
      if string.find(model, range.pattern) then
        return range.min, range.max
      end
    end
  end
  return 2700, 5000
end

-- HSV (h: 0-360, s: 0-100, v: 0-100) -> normalized RGB (each 0-1).
-- C4:ColorHSVtoRGB works on the 0-255 RGB scale.
local function hsvToRGB(h, s, v)
  local r, g, b = C4:ColorHSVtoRGB(h or 0, s or 0, v or 0)
  return (r or 0) / 255, (g or 0) / 255, (b or 0) / 255
end

-- normalized RGB (0-1) -> HSV (h: 0-360, s: 0-100, v: 0-100).
-- C4:ColorRGBtoHSV works on the 0-255 RGB scale.
local function rgbToHSV(r, g, b)
  return C4:ColorRGBtoHSV((r or 0) * 255, (g or 0) * 255, (b or 0) * 255)
end

--- Maps sysinfo capability flags to the entity shape applyUpdate expects.
--- @param sysinfo table
--- @param kelvinMin number
--- @param kelvinMax number
--- @return table entity
local function synthesizeEntity(sysinfo, kelvinMin, kelvinMax)
  local hasColor = tointeger(sysinfo.is_color) == 1
  local hasCCT = tointeger(sysinfo.is_variable_color_temp) == 1
  local hasBrightness = tointeger(sysinfo.is_dimmable) == 1

  local modes = {}
  if hasColor and hasCCT then
    table.insert(modes, ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE)
  elseif hasColor then
    table.insert(modes, ColorMode.COLOR_MODE_RGB)
  elseif hasCCT then
    table.insert(modes, ColorMode.COLOR_MODE_COLOR_TEMPERATURE)
  elseif hasBrightness then
    table.insert(modes, ColorMode.COLOR_MODE_BRIGHTNESS)
  else
    table.insert(modes, ColorMode.COLOR_MODE_ON_OFF)
  end

  local entity = { supported_color_modes = modes }
  if hasCCT then
    -- Kelvin range inverts when converted to mireds.
    entity.min_mireds = 1e6 / kelvinMax
    entity.max_mireds = 1e6 / kelvinMin
  end
  return entity
end

--- Maps a light_state to the state shape applyUpdate expects. When the bulb
--- is off, the values live under dft_on_state (the state it turns back on to).
--- While a light strip runs a lighting effect, brightness is controlled by the
--- effect state rather than the light state.
--- @param lightState table
--- @param effectState table? The sysinfo lighting_effect_state, if present.
--- @return table state
local function synthesizeState(lightState, effectState)
  local on = tointeger(lightState.on_off) == 1
  local values = on and lightState or (lightState.dft_on_state or {})

  local state = { state = on }
  if values.brightness ~= nil then
    state.brightness = (tonumber(values.brightness) or 100) / 100
  end
  if type(effectState) == "table" and tointeger(effectState.enable) == 1 and effectState.brightness ~= nil then
    state.brightness = (tonumber(effectState.brightness) or 100) / 100
  end
  local colorTemp = tonumber(values.color_temp) or 0
  if colorTemp > 0 then
    state.color_mode = ColorMode.COLOR_MODE_COLOR_TEMPERATURE
    state.color_temperature = 1e6 / colorTemp
  elseif values.hue ~= nil then
    state.color_mode = ColorMode.COLOR_MODE_RGB
    local r, g, b = hsvToRGB(tonumber(values.hue) or 0, tonumber(values.saturation) or 0, 100)
    state.red, state.green, state.blue = r, g, b
  end
  return state
end

--- Polls the bulb and maps the result for applyUpdate.
--- Rejects when the device is unreachable or is not an IOT-schema light
--- (no light_state in sysinfo), so probes can fall through.
--- @return Deferred<{ entity: table, state: table }, { error: string }>
function IotBulb:poll()
  log:trace("IotBulb:poll()")
  return self._transport:request({ system = { get_sysinfo = {} } }):next(function(response)
    local sysinfo = Select(response, "system", "get_sysinfo")
    if type(sysinfo) ~= "table" or tointeger(sysinfo.err_code) ~= 0 then
      return deferred.new():reject({ error = "IotBulb: device rejected get_sysinfo" })
    end
    if type(sysinfo.light_state) ~= "table" then
      return deferred.new():reject({ error = "IotBulb: device is not an IOT-schema light" })
    end
    self._kelvinMin, self._kelvinMax = kelvinRangeForModel(sysinfo.model)
    -- A length field marks a light strip, which takes commands through a
    -- different module (per the python-kasa device factory).
    self._isStrip = sysinfo.length ~= nil
    return {
      entity = synthesizeEntity(sysinfo, self._kelvinMin, self._kelvinMax),
      state = synthesizeState(sysinfo.light_state, sysinfo.lighting_effect_state),
    }
  end)
end

--- Translates an internal light command (ESPHome light_command shape) to a
--- transition_light_state (bulb) or set_light_state (strip) request. A ramp
--- rate is forwarded as the device-side transition_period so the device fades
--- the change itself. A bare on/off leaves ignore_default unset so the device
--- restores its previous light state. On a strip, any command takes over from
--- a lighting effect started in the Kasa app.
--- @param opts table
--- @return Deferred<table, { error: string }>
function IotBulb:execute(opts)
  log:trace("IotBulb:execute(%s)", opts)

  local params = {}
  if opts.has_state then
    params.on_off = opts.state and 1 or 0
  end
  if opts.has_brightness and opts.state ~= false then
    local level = math.floor((tonumber(opts.brightness) or 0) * 100 + 0.5)
    if level >= 1 then
      params.brightness = math.min(100, level)
      params.ignore_default = 1
    end
  end
  if opts.has_color_temperature and (tonumber(opts.color_temperature) or 0) > 0 then
    local kelvin = math.floor(1e6 / opts.color_temperature + 0.5)
    params.color_temp = math.max(self._kelvinMin, math.min(self._kelvinMax, kelvin))
    params.ignore_default = 1
  elseif opts.has_rgb then
    local h, sat = rgbToHSV(tonumber(opts.red) or 0, tonumber(opts.green) or 0, tonumber(opts.blue) or 0)
    params.hue = math.floor((h or 0) + 0.5) % 360
    params.saturation = math.max(0, math.min(100, math.floor((sat or 0) + 0.5)))
    params.color_temp = 0
    params.ignore_default = 1
  end
  if IsEmpty(params) then
    return deferred.new():resolve({})
  end
  if opts.has_transition_length then
    local ms = tointeger(opts.transition_length) or 0
    if ms > 0 then
      params.transition_period = math.min(ms, MAX_TRANSITION_MS)
    end
  end

  local service = self._isStrip and STRIP_SERVICE or BULB_SERVICE
  local method = self._isStrip and STRIP_SET_METHOD or BULB_SET_METHOD
  return self._transport:request({ [service] = { [method] = params } }):next(function(response)
    local result = Select(response, service, method)
    if type(result) ~= "table" or tointeger(result.err_code) ~= 0 then
      return deferred.new():reject({ error = "IotBulb: device rejected " .. method })
    end
    return result
  end)
end

return IotBulb
