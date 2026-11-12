--- SMART-schema mapping for TP-Link lights (Tapo bulbs and strips, newer Kasa
--- bulbs): get_device_info's result to the entity and state shapes the light
--- driver reads, and its light command to set_device_info's params. The
--- light's IOT-schema counterpart is iotbulb.lua.

local constants = require("constants")

require("drivers-common-public.global.lib")
require("lib.utils")

local ColorMode = constants.LightColorMode

--- What a light reports it can do, in the shape the light driver reads.
--- @class TplinkLightEntity
--- @field supported_color_modes integer[] LightColorMode values, the most specific first.
--- @field min_mireds number? Set for a light with color temperature.
--- @field max_mireds number?

--- A light's state, in the shape the light driver reads.
--- @class TplinkLightState
--- @field state boolean On.
--- @field brightness number? 0-1.
--- @field color_mode integer? A LightColorMode.
--- @field color_temperature number? Mireds.
--- @field red number? 0-1.
--- @field green number? 0-1.
--- @field blue number? 0-1.

--- A light command in the shape the light driver builds: each value goes with
--- its has_ flag.
--- @class TplinkLightOpts
--- @field has_state boolean?
--- @field state boolean?
--- @field has_brightness boolean?
--- @field brightness number? 0-1.
--- @field has_rgb boolean?
--- @field red number? 0-1.
--- @field green number? 0-1.
--- @field blue number? 0-1.
--- @field has_color_temperature boolean?
--- @field color_temperature number? Mireds.
--- @field has_color_mode boolean?
--- @field color_mode integer? A LightColorMode.
--- @field has_transition_length boolean?
--- @field transition_length integer? Milliseconds.

--- The fields of get_device_info's result a light is read from.
--- @class TplinkSmartInfo
--- @field device_on boolean|integer|string?
--- @field brightness number|string?
--- @field hue number|string?
--- @field saturation number|string?
--- @field color_temp number|string? Kelvin; 0 while in a color.
--- @field color_temp_range (number|string)[]? Kelvin, low then high.
--- @field mac string?

--- A color in a light request's params. The SMART and IOT schemas name it
--- alike, all three fields together.
--- @class TplinkHeldColor
--- @field hue integer? 0-359.
--- @field saturation integer? 0-100.
--- @field color_temp integer? Kelvin; 0 for a color.

--- set_device_info's params for a light.
--- @class TplinkSmartParams : TplinkHeldColor
--- @field device_on boolean?
--- @field brightness integer? 1-100.

local SmartBulb = {}

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

--- Map a get_device_info result to the entity shape the light driver reads.
--- @param info TplinkSmartInfo
--- @return TplinkLightEntity entity
function SmartBulb.entity(info)
  local hasBrightness = info.brightness ~= nil
  local hasColor = info.hue ~= nil and info.saturation ~= nil
  local kelvinMin = tointeger(Select(info, "color_temp_range", 1)) or 0
  local kelvinMax = tointeger(Select(info, "color_temp_range", 2)) or 0
  local hasCCT = info.color_temp ~= nil and kelvinMin > 0 and kelvinMax > kelvinMin

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

--- Map a get_device_info result to the state shape the light driver reads.
--- @param info TplinkSmartInfo
--- @return TplinkLightState state
function SmartBulb.state(info)
  local state = { state = toboolean(info.device_on) }
  if info.brightness ~= nil then
    state.brightness = (tofinite(tonumber_locale(info.brightness)) or 100) / 100
  end
  local colorTemp = tonumber_locale(info.color_temp) or 0
  if colorTemp > 0 then
    state.color_mode = ColorMode.COLOR_MODE_COLOR_TEMPERATURE
    state.color_temperature = 1e6 / colorTemp
  elseif info.hue ~= nil then
    state.color_mode = ColorMode.COLOR_MODE_RGB
    local r, g, b = hsvToRGB(tonumber_locale(info.hue) or 0, tonumber_locale(info.saturation) or 0, 100)
    state.red, state.green, state.blue = r, g, b
  end
  return state
end

--- Translate a light command to the params of a set_device_info request. A
--- ramp rate the command carries is not sent: the light takes no fade time
--- from a command.
--- @param opts TplinkLightOpts
--- @param entity TplinkLightEntity? The light's last report, for its Kelvin range.
--- @return TplinkSmartParams params Empty when the command names nothing the light takes.
function SmartBulb.params(opts, entity)
  local params = {}
  if opts.has_state then
    params.device_on = opts.state and true or false
  end
  if opts.has_brightness and opts.state ~= false then
    local level = math.floor((tonumber(opts.brightness) or 0) * 100 + 0.5)
    if level >= 1 then
      params.brightness = math.min(100, level)
    end
  end
  if opts.has_color_temperature and (tonumber(opts.color_temperature) or 0) > 0 then
    local kelvin = math.floor(1e6 / opts.color_temperature + 0.5)
    local maxMireds = tonumber(Select(entity or {}, "max_mireds"))
    local minMireds = tonumber(Select(entity or {}, "min_mireds"))
    local kelvinMin = (maxMireds and maxMireds > 0) and math.floor(1e6 / maxMireds + 0.5) or 2500
    local kelvinMax = (minMireds and minMireds > 0) and math.floor(1e6 / minMireds + 0.5) or 6500
    params.color_temp = math.max(kelvinMin, math.min(kelvinMax, kelvin))
  elseif opts.has_rgb then
    local h, sat = rgbToHSV(tonumber(opts.red) or 0, tonumber(opts.green) or 0, tonumber(opts.blue) or 0)
    params.hue = math.floor((h or 0) + 0.5) % 360
    params.saturation = math.max(0, math.min(100, math.floor((sat or 0) + 0.5)))
    params.color_temp = 0
  end
  return params
end

return SmartBulb
