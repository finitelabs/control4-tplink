--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "tplink_light.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-tplink"
DRIVER_FILENAMES = {
  "tplink_outlet.c4z",
  "tplink_light.c4z",
}
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif
local persist = require("lib.persist")
local constants = require("constants")
local Klap = require("lib.klap")
local Legacy = require("lib.legacy")
local IotBulb = require("lib.iotbulb")

--- Color mode identifiers shared with tplink_outlet over the TPLINK_LIGHT
--- binding protocol. The internal proxy logic keys off these the same way
--- the donor implementation keyed off ESPHome color modes.
local ColorMode = constants.LightColorMode

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------

local ON_BINDING = 300
local TOGGLE_BINDING = 301
local OFF_BINDING = 302
local PROXY_BINDING = 5001
--- Control consumer binding to a tplink_outlet output ("proxy mode"). When
--- bound, the outlet drives state and executes commands; otherwise the
--- driver connects directly to a light device using its properties.
local OUTLET_BINDING = 1

--- KLAP transport for direct mode (v2 hashing: SMART-firmware devices and
--- KL-series bulbs on newer KLAP firmware).
--- @type Klap
local klap = Klap:new()

--- KLAP transport with v1 hashing (KL-series bulbs whose KLAP firmware uses
--- the MD5-based hashes).
--- @type Klap
local klapV1 = Klap:new({ authVersion = 1 })

--- Legacy (port 9999) transport for KL-series bulbs on original firmware.
--- @type Legacy
local legacy = Legacy:new()

--- The direct-mode command schema, set by connect-time detection:
--- "smart" (Tapo-class get_device_info/set_device_info over KLAP) or "iot"
--- (KL-series sysinfo/transition_light_state via the iotBulb adapter).
--- @type string?
local directSchema = nil

--- IOT bulb adapter over the adopted transport, when directSchema is "iot".
--- @type IotBulb?
local iotBulb = nil

-- Forward declarations; assigned in the Backends section near the end.
local backendStart, backendSendCommand, backendFade

--- Human-readable name of the active transport ("Outlet", "SMART", "KLAP", or
--- "Legacy"), for Driver Status.
--- @type string?
local transportName = nil

---------------------------------------------------------------------------
-- ESPHome color modes that include brightness control
---------------------------------------------------------------------------

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_BRIGHTNESS = {
  [ColorMode.COLOR_MODE_UNKNOWN] = false,
  [ColorMode.COLOR_MODE_ON_OFF] = false,
  [ColorMode.COLOR_MODE_LEGACY_BRIGHTNESS] = true,
  [ColorMode.COLOR_MODE_BRIGHTNESS] = true,
  [ColorMode.COLOR_MODE_WHITE] = true,
  [ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_RGB = {
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_CCT = {
  [ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

---------------------------------------------------------------------------
-- Persist keys and defaults
---------------------------------------------------------------------------

local P_PRESET_LEVEL = "preset_level"
local P_CLICK_RATE_UP = "click_rate_up"
local P_CLICK_RATE_DOWN = "click_rate_down"
local P_HOLD_RATE_UP = "hold_rate_up"
local P_HOLD_RATE_DOWN = "hold_rate_down"
local P_RATE_DEFAULT = "brightness_rate_default"
local P_COLOR_RATE_DEFAULT = "color_rate_default"
local P_ON_MODE = "brightness_on_mode"
local P_BUTTON_COLORS = "button_colors"
local P_SCENES = "scenes"
local P_MAX_ON_LEVEL = "max_on_level"
local P_MIN_ON_LEVEL = "min_on_level"
local P_BRIGHTNESS_PRESETS = "brightness_presets"
local P_COLOR_PRESETS = "color_presets"
local P_COLOR_ON_MODE = "color_on_mode"
local P_PREVIOUS_COLOR = "previous_color"
local P_BRIGHTNESS_ON_MODE_PRESET = "brightness_on_mode_preset"
local P_COLOR_ON_MODE_PRESET = "color_on_mode_preset"

-- Color on-mode kinds. The proxy assigns presets with these origins/IDs to
-- distinguish dim-to-warm pairs from previous-color tracking.
local COLOR_ON_MODE_NONE = 0
local COLOR_ON_MODE_FADE = 1 -- Dim-To-Warm
local COLOR_ON_MODE_PREVIOUS = 2
local COLOR_ON_MODE_PRESET = 3

local PRESET_ORIGIN_DEVICE = 1
local PREVIOUS_ON_PRESET_ID = 10

local SCENE_TIMER_PREFIX = "Scene_"
local SCENE_RAMP_TIMER = "SceneRamp"

local DEFAULT_PRESET_LEVEL = 100
local DEFAULT_CLICK_RATE = 500
local DEFAULT_HOLD_RATE = 3000
local DEFAULT_RATE = 500

local LIGHT_COLOR_MODE_FULL = 0
local LIGHT_COLOR_MODE_CCT = 1

-- D65 whitepoint, used as a sane chromaticity default before any state is known
local DEFAULT_COLOR_X = 0.3127
local DEFAULT_COLOR_Y = 0.3290

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local ENTITY
local STATE
local currentBrightness = 0
local ledState = false
local supportsDimming = false
local supportsColor = false
local supportsCCT = false
-- The bulb's supported_color_modes from ListEntitiesLightResponse. We pick
-- the most specific mode per cmd intent (CCT vs RGB) and set color_mode
-- explicitly so ESPHome doesn't have to infer from which fields we populate.
local supportedColorModes = {}
local minMireds = 153 -- ~6500K (cool)
local maxMireds = 500 -- ~2000K (warm)
local currentColorX = DEFAULT_COLOR_X
local currentColorY = DEFAULT_COLOR_Y
local currentColorMode = LIGHT_COLOR_MODE_CCT
local dynamicCapsSent = false

-- The driver owns brightness/color state during a ramp. ESPHome echoes
-- intermediate brightness values during a transition (one echo per command
-- received - they confirm the target of each command). We delegate the
-- physical ramp to ESPHome's native transition_length and track ramp metadata
-- locally for STOP-mid-ramp interpolation via C4:GetTime() (ms precision).
local rampingBrightness = false
local rampingColor = false

-- Who makes a fade. nil: the light, over the time a command carries. Otherwise
-- the Fades property: "Driver" in steps, or "Light" at the light's own lengths.
local fades = nil

-- A light's own fades, in milliseconds, once they are read: on from off, off,
-- and change, between two states while on. 0 for one it has not.
local ownFades = {}

-- Ramp metadata: { startTime, startLevel, targetLevel, durationMs } and, for
-- a ramp a scene step primed, that step. A brightness ramp also keeps the
-- brightness it runs between (from, to), the place on the range's line of an
-- end outside the range (startAt, targetAt), and on a light the driver walks
-- the brightness of the step last sent (sentBrightness). Cleared when no ramp
-- is in flight.
local brightnessRamp = nil
local colorRamp = nil

-- The brightness the light is at, or going to: its last report, or what it
-- has been sent since. nil before it reports.
local lightBrightness = nil

-- Snapshot of brightness captured when BUTTON_ACTION PRESS arrives. The proxy
-- sends PRESS on button-down and decides click vs hold ~110ms later. By the
-- time a RELEASE_CLICK arrives, our hold ramp may have stepped 1-2%; the
-- click's ramp starts from this snapshot so a brief hold step never inverts
-- the click outcome.
local prePressBrightness = nil

-- LIGHT_BRIGHTNESS_TARGET_PRESET_ID from the proxy (Daylight Agent integration,
-- spec _2.1). Echoed back as LIGHT_BRIGHTNESS_CURRENT_PRESET_ID on subsequent
-- LIGHT_BRIGHTNESS_CHANGED so the proxy knows the active preset still owns the
-- current level. Cleared by SET_LEVEL / button presses / scene steps that
-- aren't preset-driven.
local currentBrightnessPresetId = nil

-- LIGHT_COLOR_TARGET_PRESET_ID counterpart (spec _3.1).
local currentColorPresetId = nil

--#ifndef DRIVERCENTRAL
--- Get all device IDs for instances of the TP-Link driver suite (outlet and
--- light), sorted ascending. The suite shares one GitHub updater; the
--- instance with the lowest id is the update leader regardless of type.
--- @return integer[]
local function getDriverIds()
  local ids = {}
  for _, filename in ipairs(DRIVER_FILENAMES) do
    for id, _ in pairs(C4:GetDevicesByC4iName(filename) or {}) do
      table.insert(ids, tointeger(id))
    end
  end
  table.sort(ids)
  return ids
end

--- Sync a property value to all other instances of the driver suite.
--- @param propertyName string
--- @param propertyValue string
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local ids = getDriverIds()
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(ids) do
    if deviceId ~= myId then
      log:info("Syncing property '%s' = '%s' to device %d", propertyName, propertyValue, deviceId)
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end

--- Update the driver suite from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if the drivers are up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers: %s", error)
    end)
end

--- Update Drivers action handler.
function EC.UpdateDrivers()
  log:trace("EC.UpdateDrivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end
--#endif

--- @param propertyValue string
function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
--- @param propertyValue string
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

--- The attributes of the element in `list` with this id, and this origin
--- where one is given.
local function setupPreset(list, id, origin)
  list = list or {}
  for _, element in ipairs(IsList(list) and list or { list }) do
    local attr = element._attr or {}
    if tointeger(attr.id) == id and (origin == nil or tointeger(attr.origin) == origin) then
      return attr
    end
  end
end

-- The proxy sends its on modes and default rates only when they change, never
-- at start. Its setup holds them, and it is the authority.
local function readProxySetup()
  local ok, setup = pcall(function()
    return Select(ParseXml(SendUIRequest(C4:GetProxyDevices(), "GET_SETUP", {})), "setup")
  end)
  if not ok or type(setup) ~= "table" then
    log:warn("The proxy's setup could not be read: %s", ok and "no setup in its answer" or setup)
    return
  end

  -- A preset id means one preset only with its origin: the device's own and
  -- the Color Agent's both count from 1.
  local colors = Select(setup, "colors", "color")
  local onId, onOrigin =
    tointeger(setup.light_color_on_mode_preset_id), tointeger(setup.light_color_on_mode_preset_origin)
  local fadeId = tointeger(setup.light_color_on_mode_fade_preset_id)
  local fadeOrigin = tointeger(setup.light_color_on_mode_fade_preset_origin)
  local on = onId and onOrigin and setupPreset(colors, onId, onOrigin)
  local fade = fadeId and (fadeOrigin or 0) > 0 and setupPreset(colors, fadeId, fadeOrigin) or nil
  if on and fadeOrigin and (fadeOrigin == 0 or fade) then
    fade = fade or {}
    RFP.UPDATE_COLOR_ON_MODE(PROXY_BINDING, "UPDATE_COLOR_ON_MODE", {
      COLOR_PRESET_ID = onId,
      COLOR_PRESET_ORIGIN = onOrigin,
      COLOR_PRESET_COLOR_X = on.color_x,
      COLOR_PRESET_COLOR_Y = on.color_y,
      COLOR_PRESET_COLOR_MODE = on.color_mode,
      COLOR_FADE_PRESET_ID = fadeId,
      COLOR_FADE_PRESET_ORIGIN = fadeOrigin,
      COLOR_FADE_PRESET_COLOR_X = fade.color_x,
      COLOR_FADE_PRESET_COLOR_Y = fade.color_y,
      COLOR_FADE_PRESET_COLOR_MODE = fade.color_mode,
    })
  end

  -- The proxy sends a brightness preset only when it changes, so Previous On's
  -- level is read here too.
  local levels = Select(setup, "brightnesses", "level") or {}
  for _, element in ipairs(IsList(levels) and levels or { levels }) do
    local attr = element._attr or {}
    if tointeger(attr.id) and tonumber(attr.level) then
      RFP.UPDATE_BRIGHTNESS_PRESET(
        PROXY_BINDING,
        "UPDATE_BRIGHTNESS_PRESET",
        { ID = attr.id, NAME = attr.name, LEVEL = attr.level }
      )
    end
  end

  local levelId = tointeger(setup.light_brightness_on_mode_preset_id)
  local level = levelId and setupPreset(levels, levelId)
  if level and tonumber(level.level) then
    RFP.UPDATE_BRIGHTNESS_ON_MODE(
      PROXY_BINDING,
      "UPDATE_BRIGHTNESS_ON_MODE",
      { BRIGHTNESS_PRESET_ID = levelId, BRIGHTNESS_PRESET_LEVEL = level.level }
    )
  end

  local rate = tointeger(setup.light_brightness_rate_default)
  if rate then
    RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(PROXY_BINDING, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = rate })
  end
  rate = tointeger(setup.light_color_rate_default)
  if rate then
    RFP.UPDATE_COLOR_RATE_DEFAULT(PROXY_BINDING, "UPDATE_COLOR_RATE_DEFAULT", { RATE = rate })
  end
end

---------------------------------------------------------------------------
-- Driver lifecycle
---------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  gInitialized = true

  --#ifndef DRIVERCENTRAL
  -- Periodic update check (every 30 minutes, suite leader instance only)
  SetTimer("UpdateCheck", 30 * 60 * 1000, function()
    -- Recompute leader each cycle in case the previous leader was removed
    local isLeaderInstance = Select(getDriverIds(), 1) == C4:GetDeviceID()
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  backendStart()
  readProxySetup()
end

---------------------------------------------------------------------------
-- Property handlers
---------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

---------------------------------------------------------------------------
-- Helpers: entity capabilities
---------------------------------------------------------------------------

local function entitySupportsAnyMode(entity, modeTable)
  local modes = Select(entity, "supported_color_modes")
  if not IsList(modes) then
    return false
  end
  for _, mode in ipairs(modes) do
    if modeTable[mode] then
      return true
    end
  end
  return false
end

local function entitySupportsBrightness(entity)
  return entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_BRIGHTNESS)
end

local function entitySupportsColor(entity)
  return entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_RGB)
end

local function entitySupportsCCT(entity)
  return entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_CCT)
end

local function miredsToKelvin(m)
  if not m or m <= 0 then
    return 0
  end
  return math.floor(1e6 / m + 0.5)
end

local function kelvinToMireds(k)
  if not k or k <= 0 then
    return 0
  end
  return 1e6 / k
end

--- Whose a fade's length is: a light that fades by itself has one, its own, and
--- nothing to stop. The proxy holds the rate range and the stops at run time.
local function rateCapabilities()
  local own = fades == "Light"
  -- A light with no fade between two states has no fixed rate to tell.
  local fixed = own and (ownFades.change or 0) > 0 and ownFades.change or nil
  local caps = {
    supports_brightness_stop = supportsDimming and not own,
    has_fixed_ramp_rate = fixed ~= nil,
    fixed_ramp_rate = fixed or 0,
    brightness_rate_min = fixed or 0,
    brightness_rate_max = fixed or 65535,
    supports_color_stop = false,
  }
  if supportsColor or supportsCCT then
    -- 0 is a rate that cannot be changed. 1 is one rate for brightness and
    -- color: ESPHome's transition_length applies to all aspects equally.
    caps.color_rate_behavior = own and 0 or 1
    caps.color_rate_min = 0
    caps.color_rate_max = 65535
    caps.supports_color_stop = not own
  end
  return caps
end

local function updateDynamicCapabilities(entity)
  if dynamicCapsSent then
    return
  end
  supportsDimming = entitySupportsBrightness(entity)
  supportsColor = entitySupportsColor(entity)
  supportsCCT = entitySupportsCCT(entity)
  supportedColorModes = {}
  local modes = Select(entity, "supported_color_modes")
  if IsList(modes) then
    for _, m in ipairs(modes) do
      supportedColorModes[m] = true
    end
  end
  -- Some ESPHome entities report 0/0 for mireds. Keep our XML defaults in that case
  -- so Composer's dialog doesn't get broken bounds.
  local entityMin = tonumber(Select(entity, "min_mireds"))
  local entityMax = tonumber(Select(entity, "max_mireds"))
  if entityMin and entityMin > 0 then
    minMireds = entityMin
  end
  if entityMax and entityMax > 0 then
    maxMireds = entityMax
  end

  log:info(
    "Entity caps: brightness=%s color=%s cct=%s mireds=[%.1f, %.1f]",
    tostring(supportsDimming),
    tostring(supportsColor),
    tostring(supportsCCT),
    minMireds,
    maxMireds
  )

  -- Emit the FULL set of dynamic capabilities (everything spec'd as
  -- "Dynamic Capability: Yes" in the LIGHT_V2 cap docs, plus dynamic-only
  -- caps from DYNAMIC_CAPABILITIES_CHANGED). Composer reads these at
  -- runtime to gate UI elements; the static driver.xml values are only
  -- the design-time defaults. Emitting the full set ensures Navigators
  -- and Composer test panels reflect the actual bulb's capabilities.
  local caps = {
    -- Brightness/dimmer
    dimmer = supportsDimming,
    set_level = supportsDimming,
    supports_target = supportsDimming,
    ramp_level = supportsDimming, -- legacy 3.2-era cap; still gates test panel Ramp button
    -- Color
    supports_color = supportsColor,
    supports_color_correlated_temperature = supportsCCT,
    -- Misc
    has_extras = false,
    cold_start = false,
    color_trace_tolerance = 2, -- xy round-trip through HSV/RGB drifts ~1; use 2 for margin
  }
  if supportsCCT then
    -- CIE mireds invert vs Kelvin, so swap min/max during conversion.
    caps.color_correlated_temperature_min = miredsToKelvin(maxMireds)
    caps.color_correlated_temperature_max = miredsToKelvin(minMireds)
  end
  for capability, value in pairs(rateCapabilities()) do
    caps[capability] = value
  end
  -- Told only where the proxy's Navigator Dynamic Capabilities (6661) list another: after a controller start it fires
  -- its color variables' events for any it is told. It lists supports_color_stop False without CCT, whatever it is told.
  local ok, xml = pcall(function()
    return C4:GetDeviceVariable(C4:GetProxyDevices(), 6661)
  end)
  local shown, same = {}, nil
  for key, value in string.gmatch(ok and tostring(xml or "") or "", "<([%w_]+)>([^<]*)</%1>") do
    shown[key] = value
  end
  for key, value in pairs(caps) do
    if shown[key] ~= nil and key ~= "supports_color_stop" then
      local want = type(value) == "boolean" and (value and "True" or "False") or value
      same = same ~= false and (shown[key] == want or tonumber(shown[key]) == want)
    end
  end
  if same then
    log:debug("The proxy shows the light's capabilities")
  else
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", caps, "NOTIFY", true)
  end

  -- Tell the proxy we have three virtual buttons (top/bottom/toggle). Sent as
  -- a string per the LIGHT_V2 NUMBER_BUTTONS notify format. Then emit a
  -- BUTTON_INFO for each so Composer's GET_SETUP can populate names.
  SendToProxy(PROXY_BINDING, "NUMBER_BUTTONS", "3", "NOTIFY")
  local buttonNames = {
    [constants.ButtonIds.TOP] = "Top",
    [constants.ButtonIds.BOTTOM] = "Bottom",
    [constants.ButtonIds.TOGGLE] = "Toggle",
  }
  for buttonId, name in pairs(buttonNames) do
    local colors = persist:get(P_BUTTON_COLORS, {})
    local saved = colors[tostring(buttonId)] or {}
    SendToProxy(PROXY_BINDING, "BUTTON_INFO", {
      BUTTON_ID = buttonId,
      NAME = name,
      ON_COLOR = saved.on_color or "",
      OFF_COLOR = saved.off_color or "",
    }, "NOTIFY")
  end

  -- Re-emit the persisted preset level so the proxy is seeded after a reload.
  local presetLevel = tointeger(persist:get(P_PRESET_LEVEL))
  if presetLevel and presetLevel > 0 then
    SendToProxy(PROXY_BINDING, "PRESET_LEVEL", tostring(presetLevel), "NOTIFY")
  end

  -- Set last so a mid-function error retries on the next UPDATE_STATE rather
  -- than leaving the proxy with a half-applied capability set.
  dynamicCapsSent = true
end

---------------------------------------------------------------------------
-- Helpers: color conversions
---------------------------------------------------------------------------

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

-- CIE 1931 xy chromaticity -> normalized RGB at full intensity.
-- Brightness is handled separately via the LIGHT_V2 brightness path.
local function xyToRGB(x, y)
  local h, s = C4:ColorXYtoHSV(x, y)
  local r, g, b = hsvToRGB(h or 0, s or 100, 100)
  return r, g, b
end

-- xy colors this close are one color: an RGB / HSV round trip drifts 1-2e-3.
local COLOR_TOLERANCE = 5e-3

local function sameColor(x1, y1, mode1, x2, y2, mode2)
  return mode1 == mode2 and math.abs(x1 - x2) <= COLOR_TOLERANCE and math.abs(y1 - y2) <= COLOR_TOLERANCE
end

---------------------------------------------------------------------------
-- Helpers: persistence
---------------------------------------------------------------------------

-- Clamp the persisted preset to a usable on-level. The proxy may send 0 via
-- SET_PRESET_LEVEL during testing; treat anything < 1 as "use the default" so
-- a tap of On/Toggle doesn't end up turning the light off.
local function getPresetLevel()
  local v = tointeger(persist:get(P_PRESET_LEVEL))
  if not v or v < 1 then
    return DEFAULT_PRESET_LEVEL
  end
  return math.min(v, 100)
end

local function getOnBrightness()
  local level = tointeger(persist:get(P_ON_MODE, {}).level)
  if level and level >= 1 then
    return math.min(level, 100)
  end
  return getPresetLevel()
end

local function getDefaultRate()
  return persist:get(P_RATE_DEFAULT, DEFAULT_RATE)
end

-- ESPHome's transition_length applies to all aspects of a light_command
-- (brightness, color, color temperature) at the same time, so we declare
-- color_rate_behavior=1 ("Device only supports one rate for brightness and
-- color"). Composer in turn shows a single "Default Brightness and Color
-- Rate" setting; the brightness and color defaults are the same value. If
-- nothing has been persisted yet for color we fall back to the brightness
-- default rather than the hard-coded constant so the two can never drift.
-- Read as a number: a key never stored reads as nil.
local function getDefaultColorRate()
  return tointeger(persist:get(P_COLOR_RATE_DEFAULT)) or getDefaultRate()
end

local function getClickRateUp()
  return persist:get(P_CLICK_RATE_UP, DEFAULT_CLICK_RATE)
end

local function getClickRateDown()
  return persist:get(P_CLICK_RATE_DOWN, DEFAULT_CLICK_RATE)
end

local function getHoldRateUp()
  return persist:get(P_HOLD_RATE_UP, DEFAULT_HOLD_RATE)
end

local function getHoldRateDown()
  return persist:get(P_HOLD_RATE_DOWN, DEFAULT_HOLD_RATE)
end

local function getButtonColors(buttonId)
  local colors = persist:get(P_BUTTON_COLORS, {})
  local key = tostring(buttonId)
  if colors[key] then
    return colors[key].on_color or "0000ff", colors[key].off_color or "000000"
  end
  return "0000ff", "000000"
end

local function setButtonColors(buttonId, onColor, offColor)
  local colors = persist:get(P_BUTTON_COLORS, {})
  local key = tostring(buttonId)
  local existing = colors[key] or {}
  colors[key] = {
    on_color = onColor or existing.on_color or "0000ff",
    off_color = offColor or existing.off_color or "000000",
  }
  persist:set(P_BUTTON_COLORS, colors)
end

---------------------------------------------------------------------------
-- Helpers: on-level range
---------------------------------------------------------------------------
-- Levels 1-100 run between the Min and Max On Level, as on a Control4 dimmer.
-- One table, not a local each: this chunk is near Lua's 200 locals.
local range = {}

-- Device brightness (percent) that levels 1-100 map onto.
function range.bounds()
  local lo = math.max(1, tonumber(persist:get(P_MIN_ON_LEVEL, 1)) or 1)
  return lo, math.max(lo, tonumber(persist:get(P_MAX_ON_LEVEL, 100)) or 100)
end

--- Device brightness (percent) at level `at` on the line through (1, lo) and
--- (100, hi); extrapolates past either end. With no range it is `at` exactly.
function range.linePercent(at)
  local lo, hi = range.bounds()
  return lo + (at - 1) * ((hi - lo) / 99)
end

function range.lineBrightness(at)
  return range.linePercent(at) / 100
end

function range.toDevice(level)
  return level > 0 and range.lineBrightness(level) or 0
end

--- Inverse of lineBrightness; nil when the range has no width.
function range.linePlace(brightness)
  local lo, hi = range.bounds()
  return hi > lo and 1 + (brightness * 100 - lo) * 99 / (hi - lo) or nil
end

--- Level a brightness reads back as: 0 for off, and an on one clamped to the
--- range's ends.
function range.readLevel(brightness)
  if brightness <= 0 then
    return 0
  end
  return math.max(1, math.min(100, math.floor((range.linePlace(brightness) or 100) + 0.5)))
end

-- A zero-width range reads every on level back as the same one.
function range.sameLevel(a, b)
  local lo, hi = range.bounds()
  return a == b or (a > 0 and b > 0 and hi == lo)
end

-- Line position of brightness 0: a fade to or from off runs below level 1.
function range.offLevel()
  return range.linePlace(0) or 0
end

-- A light left outside the range (e.g. a new one) reads back as the range's
-- end without being there. The 1e-5 margin absorbs float error.
function range.outsideRange(brightness)
  local lo, hi = range.bounds()
  return brightness > 0 and (brightness < lo / 100 - 1e-5 or brightness > hi / 100 + 1e-5)
end

-- Line position of a light outside the range; nil inside it.
function range.outsideAt(brightness)
  return range.outsideRange(brightness) and range.linePlace(brightness) or nil
end

-- Device brightness for a level, or for a line position outside the range.
function range.endBrightness(level, at)
  return at and range.lineBrightness(at) or range.toDevice(level)
end

-- A TP-Link light takes and reports its brightness in whole percents.
function range.wholePercent(brightness)
  return math.floor(brightness * 100 + 0.5)
end

-- The level a light read at a brightness shows. A range puts levels between
-- whole percents, so the light at the one the level shown goes out at is there.
function range.shownLevel(brightness)
  local percent = range.wholePercent(brightness)
  if currentBrightness > 0 and range.wholePercent(range.toDevice(currentBrightness)) == percent then
    return currentBrightness
  end
  return range.readLevel(brightness)
end

--- A ramp's line position `elapsed` ms in, and off's: a fade to or from off
--- runs from or to below level 1.
function range.rampPlace(ramp, elapsed)
  local off = range.offLevel()
  local from = ramp.startLevel > 0 and (ramp.startAt or ramp.startLevel) or off
  local to = ramp.targetLevel > 0 and (ramp.targetAt or ramp.targetLevel) or off
  return from + (to - from) * (elapsed / ramp.durationMs), off
end

--- Level a ramp's line position reads as, and the position if outside the
--- range.
--- @param toggle boolean|nil Count as on from half a level above off.
function range.placeLevel(ramp, at, off, toggle)
  local lit = ramp.startLevel > 0 and ramp.targetLevel > 0
  if not lit and at < (toggle and off + 0.5 or (1 + off) / 2) then
    return 0
  end
  -- Past either end keep the position, except below level 1 on a fade to or
  -- from off, which holds at the Min.
  local outside = at > 100 or (lit and at < 1)
  return math.max(1, math.min(100, math.floor(at + 0.5))), outside and at or nil
end

--- Where a walk's line has the light: the level, and the brightness in whole
--- percents. A fade to or from off passes under the Min, as a light fading by
--- itself does.
function range.walk(ramp)
  local elapsed = C4:GetTime() - ramp.startTime
  if elapsed <= 0 then
    return ramp.startLevel, range.wholePercent(ramp.from)
  end
  if elapsed >= ramp.durationMs then
    return ramp.targetLevel, range.wholePercent(range.endBrightness(ramp.targetLevel, ramp.targetAt))
  end
  local at = range.rampPlace(ramp, elapsed)
  local percent = math.floor(math.max(0, range.linePercent(at)) + 0.5)
  -- A walk up from off is lit from its first step, as the proxy is told.
  if ramp.targetLevel > 0 then
    percent = math.max(1, percent)
  end
  return percent > 0 and math.max(1, math.min(100, math.floor(at + 0.5))) or 0, percent
end

---------------------------------------------------------------------------
-- Helpers: ESPHome light commands
---------------------------------------------------------------------------

local function sendLightCommand(opts)
  log:debug("sendLightCommand(%s)", opts)
  if opts.has_brightness or opts.state == false then
    lightBrightness = opts.state and opts.brightness or 0
  end
  backendSendCommand(opts)
end

-- Pick the most specific ESPHome color mode the bulb supports for a given
-- intent ("cct" or "rgb"). Order matters: prefer single-purpose modes (RGB,
-- COLD_WARM_WHITE) over combined modes (RGB_COLOR_TEMPERATURE,
-- RGB_COLD_WARM_WHITE) because the bulb's behavior in single-purpose modes
-- is unambiguous. Returns nil if no compatible mode is supported.
local function pickColorMode(intent)
  local CM = ColorMode
  local order
  if intent == "cct" then
    order = {
      CM.COLOR_MODE_COLD_WARM_WHITE,
      CM.COLOR_MODE_COLOR_TEMPERATURE,
      CM.COLOR_MODE_RGB_COLD_WARM_WHITE,
      CM.COLOR_MODE_RGB_COLOR_TEMPERATURE,
    }
  else
    order = {
      CM.COLOR_MODE_RGB,
      CM.COLOR_MODE_RGB_WHITE,
      CM.COLOR_MODE_RGB_COLOR_TEMPERATURE,
      CM.COLOR_MODE_RGB_COLD_WARM_WHITE,
    }
  end
  for _, m in ipairs(order) do
    if supportedColorModes[m] then
      return m
    end
  end
  return nil
end

-- Map a target Kelvin to a (cold_white, warm_white) channel split based on
-- the bulb's reported mireds range. Pure cold = (1, 0) at min_mireds; pure
-- warm = (0, 1) at max_mireds; linear blend between. Returned values are 0-1
-- floats matching ESPHome's per-channel scale.
local function kelvinToCoolWarmSplit(kelvin)
  local mireds = kelvinToMireds(kelvin)
  local span = maxMireds - minMireds
  if span <= 0 then
    return 0.5, 0.5
  end
  local ratio = math.max(0, math.min(1, (mireds - minMireds) / span))
  return 1 - ratio, ratio
end

-- Convert an XY/mode color into the right ESPHome cmd fields. Returns the
-- partial cmd table or nil if the bulb doesn't support color/CCT or the
-- provided values can't be mapped.
local function buildColorCmdFields(x, y, mode)
  if not (supportsColor or supportsCCT) or x == nil or y == nil then
    return nil
  end
  if mode == LIGHT_COLOR_MODE_CCT and supportsCCT then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if not k or k <= 0 then
      return nil
    end
    local fields = {
      has_color_temperature = true,
      color_temperature = kelvinToMireds(k),
    }
    -- Set color_mode explicitly so ESPHome doesn't have to infer.
    local pickedMode = pickColorMode("cct")
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    -- For RGBCW / cold-warm-white capable bulbs, also drive the cold/warm
    -- channels directly. ESPHome would compute these internally from
    -- color_temperature, but sending them ourselves removes ambiguity in
    -- min_mireds/max_mireds reading and keeps the channel split exactly
    -- where we expect it.
    local CM = ColorMode
    if supportedColorModes[CM.COLOR_MODE_COLD_WARM_WHITE] or supportedColorModes[CM.COLOR_MODE_RGB_COLD_WARM_WHITE] then
      local cw, ww = kelvinToCoolWarmSplit(k)
      fields.has_cold_white = true
      fields.cold_white = cw
      fields.has_warm_white = true
      fields.warm_white = ww
    end
    return fields
  end
  if supportsColor then
    local r, g, b = xyToRGB(x, y)
    local fields = { has_rgb = true, red = r, green = g, blue = b }
    local pickedMode = pickColorMode("rgb")
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    return fields
  end
  return nil
end

-- A color temperature outside the light's range is taken at its nearest end.
local function clampKelvin(k)
  return math.max(miredsToKelvin(maxMireds), math.min(miredsToKelvin(minMireds), k))
end

-- A color as the light takes it, which its reports then read as: the point of
-- its color temperature, or a full color on a light with no color temperature.
local function takenColor(x, y, mode)
  if mode ~= LIGHT_COLOR_MODE_CCT then
    return x, y, mode
  end
  if not supportsCCT then
    return x, y, supportsColor and LIGHT_COLOR_MODE_FULL or mode
  end
  local k = tonumber(C4:ColorXYtoCCT(x, y))
  if k and k > 0 then
    x, y = C4:ColorCCTtoXY(clampKelvin(k))
  end
  return x, y, mode
end

-- Apply the dim-to-warm formula from spec _7.2:
--   colorFinal.x = colorDim.x + (colorOn.x - colorDim.x) * brightness*.01
--   colorFinal.y = colorDim.y + (colorOn.y - colorDim.y) * brightness*.01
-- The "On" color is the color at 100%, "Dim" is the color at 1%. We get
-- both via UPDATE_COLOR_ON_MODE (onPreset = on color, fadePreset = dim
-- color). Returns nil if either color is missing or fade mode isn't active.
local function computeFadeColor(brightness)
  local mode = persist:get(P_COLOR_ON_MODE, {})
  local onPreset = mode.onPreset
  local dimPreset = mode.fadePreset
  if not onPreset or not dimPreset then
    return nil
  end
  if onPreset.x == nil or onPreset.y == nil or dimPreset.x == nil or dimPreset.y == nil then
    return nil
  end
  local b = math.max(0, math.min(100, brightness)) * 0.01
  local x, y, colorMode = takenColor(
    dimPreset.x + (onPreset.x - dimPreset.x) * b,
    dimPreset.y + (onPreset.y - dimPreset.y) * b,
    onPreset.mode or LIGHT_COLOR_MODE_FULL
  )
  return { x = x, y = y, mode = colorMode }
end

-- Determine which color on-mode is currently active. Returns one of
-- COLOR_ON_MODE_* constants.
local function getColorOnModeKind()
  if not (supportsColor or supportsCCT) then
    return COLOR_ON_MODE_NONE
  end
  local mode = persist:get(P_COLOR_ON_MODE, {})
  if not mode.fadePreset then
    return COLOR_ON_MODE_NONE
  end
  local fadeOrigin = mode.fadePreset.origin
  if fadeOrigin and fadeOrigin > 0 then
    -- Origin > 0 indicates fade is enabled (spec _21: origin 1=device, 2=agent).
    return COLOR_ON_MODE_FADE
  end
  local onPreset = mode.onPreset
  if onPreset and onPreset.id == PREVIOUS_ON_PRESET_ID and onPreset.origin == PRESET_ORIGIN_DEVICE then
    return COLOR_ON_MODE_PREVIOUS
  end
  if onPreset and onPreset.x then
    return COLOR_ON_MODE_PRESET
  end
  return COLOR_ON_MODE_NONE
end

-- The bulb is "logically on" if either we already think it's on or a ramp
-- is in flight targeting an on-state. Used so a SET_COLOR_TARGET arriving
-- mid-ramp from off→on doesn't send state=false (which kills the brightness
-- fade by reverting the bulb to off).
local function isLogicallyOn()
  if rampingBrightness and brightnessRamp and (brightnessRamp.targetLevel or 0) > 0 then
    return true
  end
  return currentBrightness > 0
end

-- Determine the on-color to use when transitioning from off to on, based on
-- the active color on-mode. Returns {x, y, mode} or nil.
local function resolveOnColor(brightnessLevel)
  if not (supportsColor or supportsCCT) then
    return nil
  end
  local kind = getColorOnModeKind()
  if kind == COLOR_ON_MODE_FADE then
    return computeFadeColor(brightnessLevel)
  end
  if kind == COLOR_ON_MODE_PREVIOUS then
    local prev = persist:get(P_PREVIOUS_COLOR, {})
    if prev.x and prev.y then
      return { x = prev.x, y = prev.y, mode = prev.mode or LIGHT_COLOR_MODE_FULL }
    end
  end
  if kind == COLOR_ON_MODE_PRESET then
    local onPreset = persist:get(P_COLOR_ON_MODE, {}).onPreset
    if onPreset and onPreset.x and onPreset.y then
      local x, y, colorMode = takenColor(onPreset.x, onPreset.y, onPreset.mode or LIGHT_COLOR_MODE_FULL)
      return { x = x, y = y, mode = colorMode }
    end
  end
  return nil
end

-- Tracks a recent off→on cmd that already carried the on-color. The proxy
-- typically follows a SET_BRIGHTNESS_TARGET with a SET_COLOR_TARGET that
-- carries the same color it already set in our brightness cmd; we use this
-- timestamp to deduplicate and avoid sending a redundant ESPHome cmd that
-- would otherwise restart the in-flight transition.
local mergedColorUntil = 0

---------------------------------------------------------------------------
-- Helpers: color notifications
---------------------------------------------------------------------------

local function notifyColorChanged(x, y, mode)
  currentColorX = x
  currentColorY = y
  currentColorMode = mode
  log:debug("LIGHT_COLOR_CHANGED: x=%.4f y=%.4f mode=%s", x, y, mode)
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
    LIGHT_COLOR_CURRENT_PRESET_ID = currentColorPresetId,
  }, "NOTIFY")
end

local function notifyColorChanging(targetX, targetY, mode, rate)
  log:debug("LIGHT_COLOR_CHANGING: x=%.4f y=%.4f mode=%s rate=%s", targetX, targetY, mode, rate)
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_CURRENT_X = currentColorX,
    LIGHT_COLOR_CURRENT_Y = currentColorY,
    LIGHT_COLOR_CURRENT_COLOR_MODE = currentColorMode,
    LIGHT_COLOR_TARGET_X = targetX,
    LIGHT_COLOR_TARGET_Y = targetY,
    LIGHT_COLOR_TARGET_COLOR_MODE = mode,
    -- Spec _10.7 names this LIGHT_COLOR_TARGET_COLOR_RATE; some older docs
    -- and helper code use LIGHT_COLOR_TARGET_RATE so we send both for safety.
    LIGHT_COLOR_TARGET_COLOR_RATE = rate,
    LIGHT_COLOR_TARGET_RATE = rate,
    LIGHT_COLOR_TARGET_PRESET_ID = currentColorPresetId,
  }, "NOTIFY", true)
end

---------------------------------------------------------------------------
-- Helpers: brightness notifications
---------------------------------------------------------------------------

local function endOnCycle()
  -- A color the driver walks goes on to its end while the light is off, so the
  -- proxy hears it ahead of the level, where it takes its Previous On.
  if fades == "Driver" and rampingColor then
    colorRamp.told = true
    notifyColorChanged(colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode)
  end
  -- Snapshot the current color so color_on_mode_previous can restore it on the
  -- next on. Spec _7.4: "the proxy tracks the last color reported by a driver
  -- before a BRIGHTNESS_CHANGED notification occurs with a level of 0." We
  -- mirror that locally for non-proxy paths.
  persist:set(P_PREVIOUS_COLOR, {
    x = currentColorX,
    y = currentColorY,
    mode = currentColorMode,
  })
  -- Drop any color preset id: whatever drove this on-cycle's color does not
  -- apply once the light is off.
  currentColorPresetId = nil
end

-- Tell the button LEDs whether the light is on, when that has changed.
local function matchLedState(on)
  if on == ledState then
    return
  end
  ledState = on
  -- MATCH_LED_STATE goes to each BUTTON_LINK binding (the keypad button
  -- LEDs), not to the LIGHT_V2 proxy binding. STATE is a Lua boolean per
  -- spec. Bottom is inverted: its LED lights when the light is OFF.
  SendToProxy(ON_BINDING, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
  SendToProxy(OFF_BINDING, "MATCH_LED_STATE", { STATE = not on }, "NOTIFY", true)
  SendToProxy(TOGGLE_BINDING, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
end

-- The last level the proxy was told is a ramp's 1 from off, not one the light
-- was at.
local preOnTold = false

local function previousOnLevel()
  local preset = persist:get(P_BRIGHTNESS_PRESETS, {})[tostring(PREVIOUS_ON_PRESET_ID)]
  return preset and tonumber(preset.level)
end

local function notifyBrightnessChanged(level)
  if level == 0 and currentBrightness > 0 then
    endOnCycle()
  end
  -- The proxy takes Previous On from the last level it was told, so tell the
  -- one to keep as an off from it.
  if level == 0 and preOnTold then
    local keep = currentBrightness > 0 and currentBrightness or previousOnLevel()
    if keep and keep >= 1 then
      log:debug("LIGHT_BRIGHTNESS_CHANGING: %s to 0, rate=0", keep)
      SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGING", {
        LIGHT_BRIGHTNESS_CURRENT = keep,
        LIGHT_BRIGHTNESS_TARGET = 0,
        RATE = 0,
      }, "NOTIFY", true)
    end
  end
  preOnTold = false
  currentBrightness = level
  log:debug("LIGHT_BRIGHTNESS_CHANGED: %s", level)
  -- Echo back the preset id from the most recent SET_BRIGHTNESS_TARGET so the
  -- proxy / Daylight Agent (spec _10.2 / _2.1) knows the active preset still
  -- owns the current level. Nil keys are dropped from the table at construct
  -- time, so this is equivalent to omitting the field when no preset is set.
  SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGED", {
    LIGHT_BRIGHTNESS_CURRENT = level,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = currentBrightnessPresetId,
  }, "NOTIFY")
  matchLedState(level > 0)
end

--- @param current number? Where the light has got to, if not where the ramp began.
local function notifyBrightnessChanging(target, rate, current)
  log:debug("LIGHT_BRIGHTNESS_CHANGING: target=%s rate=%s", target, rate)
  -- The proxy takes the light's state from CURRENT: one on its way up from off
  -- is lit by the first request the fade sends.
  current = current or currentBrightness
  preOnTold = target > 0 and current < 1
  if target > 0 then
    current = math.max(1, current)
  end
  SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGING", {
    LIGHT_BRIGHTNESS_CURRENT = current,
    LIGHT_BRIGHTNESS_TARGET = target,
    RATE = rate,
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = currentBrightnessPresetId,
  }, "NOTIFY", true)
  -- A light on its way up is on from the start of its ramp, as one fading to
  -- off is on until its end.
  if target > 0 then
    matchLedState(true)
  end
end

local leaveColorRamp -- defined with the color ramp helpers below

-- A color a replaced fade carried, or one told at an off, on a light the driver
-- walks: helpers below, in one table as this chunk is near Lua's 200 locals.
local carry = {}

-- Two-phase fade-up workaround. ESPHome's light_call short-circuits on
-- state=false: brightness=0 in the same command is dropped, so the bulb's
-- stored brightness stays at whatever it was last set to (often 1.0).
-- When we then send state=true brightness=target with transition_length,
-- ESPHome sees no brightness diff and the LED snaps on instead of fading.
-- Pre-pushing a state=true brightness=ε with transition=0 sets the stored
-- brightness to ~0 so the real ramp has a real diff to interpolate across.
-- 0.0039 = 1/256, the smallest 8-bit PWM step, visually indistinguishable
-- from off. Using literal 0 risks ESPHome converting state=true brightness=0
-- back into state=false.
local function sendPreOn()
  sendLightCommand({
    has_state = true,
    state = true,
    has_brightness = true,
    brightness = 0.0039,
    has_transition_length = true,
    transition_length = 0,
  })
end

-- Caller contract: only invoked when supportsDimming is true (lightOn/Off,
-- rampToBrightness, scene apply, etc. all gate on it). On/off-only entities
-- get a different code path that doesn't touch brightness.
--- @param at number|nil Line position for a light held outside the range.
local function setESPHomeBrightness(level, rateMs, keepColor, at)
  local hasRate = rateMs and rateMs > 0
  local goingOn = level > 0 and currentBrightness == 0

  if goingOn and hasRate then
    sendPreOn()
  end

  -- Always include both state AND brightness in the command. The brightness
  -- field is dropped by ESPHome when state=false (see workaround above), but
  -- including it for state=true is essential for the transition.
  local cmd = {
    has_state = true,
    state = level > 0,
    has_brightness = true,
    brightness = range.endBrightness(level, at),
    has_transition_length = true,
    -- A rate of 0 still gets sent so it cancels any in-flight transition on
    -- the device rather than falling back to its default_transition_length.
    transition_length = hasRate and rateMs or 0,
  }

  -- Merge color into the brightness cmd so brightness+color animate as one
  -- ESPHome transition. Two scenarios:
  --   1. Dim-to-warm during any brightness change while fade mode is active:
  --      recompute via the formula every step. Spec _7.2: a color set with
  --      SET_COLOR_TARGET lasts until the next brightness command.
  --   2. Off→on with any color on-mode (fade/previous/preset) — apply the
  --      configured on-color in the same cmd. The proxy will typically also
  --      send a SET_COLOR_TARGET right after this; mergedColorUntil makes
  --      the SET_COLOR_TARGET handler skip a redundant ESPHome cmd that
  --      would otherwise cancel and restart the in-flight transition.
  local mergedColor = nil
  -- A stop after a color was set sends the level alone.
  if not keepColor then
    if level > 0 and getColorOnModeKind() == COLOR_ON_MODE_FADE then
      mergedColor = computeFadeColor(level)
    elseif goingOn then
      mergedColor = resolveOnColor(level)
    end
  end
  local mergedColorApplied = false
  if mergedColor then
    local colorFields = buildColorCmdFields(mergedColor.x, mergedColor.y, mergedColor.mode)
    if colorFields then
      for k, v in pairs(colorFields) do
        cmd[k] = v
      end
      mergedColorApplied = true
      -- Window during which a follow-up SET_COLOR_TARGET targeting the same
      -- color is treated as already applied. 250ms covers the proxy's
      -- typical inter-cmd gap (~6-50ms) with a margin.
      mergedColorUntil = C4:GetTime() + 250
      -- The merged color is computed from on-mode rules (fade/previous/
      -- on-preset), not from an explicit SET_COLOR_TARGET. Clear any
      -- lingering target-preset id so we don't echo a stale value. If the
      -- proxy follows up with a SET_COLOR_TARGET inside mergedColorUntil,
      -- that handler will set the correct id before brightnessRampFinished
      -- emits the terminal LIGHT_COLOR_CHANGED.
      currentColorPresetId = nil
      -- Stash on the ramp metadata so brightnessRampFinished can emit the
      -- terminal LIGHT_COLOR_CHANGED when the bulb's combined transition
      -- completes. The proxy needs CHANGING (now) + CHANGED (at finish) to
      -- keep its color-picker animation in sync.
      if brightnessRamp then
        brightnessRamp.mergedColor = {
          x = mergedColor.x,
          y = mergedColor.y,
          mode = mergedColor.mode,
        }
      end
    end
  end
  sendLightCommand(cmd)
  -- Emit color CHANGING/CHANGED to mirror the brightness side: the proxy
  -- doesn't always issue a SET_COLOR_TARGET (e.g. fade mode drives color
  -- from the formula, not from a separate proxy-initiated cmd), so the
  -- driver has to push these notifies for the picker to track.
  if mergedColorApplied then
    -- The color sent last is where the light goes, so a color ramp in flight
    -- ends here: its end would report, and re-send, a color it has left.
    leaveColorRamp()
    if hasRate then
      -- CHANGING reports the color left: the ramp's end sets the target.
      notifyColorChanging(mergedColor.x, mergedColor.y, mergedColor.mode, rateMs)
    else
      notifyColorChanged(mergedColor.x, mergedColor.y, mergedColor.mode)
    end
  else
    carry.retime(cmd.transition_length, level > 0)
    if goingOn then
      carry.resume()
    end
  end
end

---------------------------------------------------------------------------
-- Helpers: brightness ramping
---------------------------------------------------------------------------
-- ESPHome has native transition_length smoothing on the bulb itself. We send
-- a single light_command with the full rate, ESPHome handles the physical
-- ramp, and we track elapsed time locally so SET_BRIGHTNESS_STOP can
-- interpolate the device's current level mid-ramp using C4:GetTime() (ms).
--
-- ESPHome echoes one UPDATE_STATE per command it receives confirming the
-- target. During a ramp we ignore those echoes (rampingBrightness=true).
-- After the ramp ends we ignore brightness echoes for an additional grace
-- window in case stale echoes from a prior cmd arrive late and would
-- otherwise re-mutate currentBrightness and bounce the UI.

local function cancelBrightnessRampTimers()
  CancelTimer("BrightnessRampFinish")
end

--- Level a ramp has the light at, and its line position if outside the range.
--- @param toggle boolean|nil Count as on from half a level above off.
local function interpolatedBrightness(toggle)
  local ramp = brightnessRamp
  if not ramp or ramp.durationMs <= 0 then
    return currentBrightness
  end
  -- A light the driver walks is where its last step put it, behind the line.
  if fades == "Driver" then
    if ramp.sentBrightness == nil then
      return ramp.startLevel, ramp.startAt
    end
    return range.readLevel(ramp.sentBrightness), range.outsideAt(ramp.sentBrightness)
  end
  local elapsed = C4:GetTime() - ramp.startTime
  if elapsed <= 0 then
    return ramp.startLevel, ramp.startAt
  end
  if elapsed >= ramp.durationMs then
    return ramp.targetLevel, ramp.targetAt
  end
  local at, off = range.rampPlace(ramp, elapsed)
  return range.placeLevel(ramp, at, off, toggle)
end

--- How long a change takes: the time asked for, or on a light that fades by
--- itself its own time for that change, whatever was asked.
local function fadeTime(rate, from, to)
  if fades ~= "Light" then
    return rate
  end
  local own = ownFades.change
  if to == 0 then
    own = from ~= 0 and ownFades.off
  elseif from == 0 then
    own = ownFades.on
  end
  return own or 0
end

local function brightnessRampFinished(targetLevel)
  cancelBrightnessRampTimers()
  if fades == "Driver" and rampingBrightness then
    -- The last step. The ramp is at its end from here, whenever this is.
    brightnessRamp.startTime = C4:GetTime() - brightnessRamp.durationMs
    backendFade(true)
  end
  -- Capture mergedColor before nilling brightnessRamp so we can emit a
  -- terminal LIGHT_COLOR_CHANGED for the color that piggybacked on this
  -- ramp's transition_length (off→on with a configured on-color).
  local mergedColor = brightnessRamp and brightnessRamp.mergedColor
  rampingBrightness = false
  brightnessRamp = nil
  notifyBrightnessChanged(targetLevel)
  if mergedColor then
    notifyColorChanged(mergedColor.x, mergedColor.y, mergedColor.mode)
  end
end

-- Halt the in-flight ESPHome transition at our interpolated current level.
local function brightnessRampStopped()
  -- A light that fades by itself is on its way: it has no stop to be sent.
  if fades == "Light" then
    return
  end
  cancelBrightnessRampTimers()
  if not rampingBrightness then
    return
  end
  local stoppedAt, at = interpolatedBrightness()
  -- A color ramping, or set during this ramp, is not the level's to replace.
  local keepColor = rampingColor or brightnessRamp.colorSet
  local ramp = brightnessRamp
  rampingBrightness = false
  brightnessRamp = nil
  if fades == "Driver" then
    -- A color a replaced fade carried moves with this ramp: it stops with it.
    if rampingColor and colorRamp.carried then
      leaveColorRamp()
      notifyColorChanged(currentColorX, currentColorY, currentColorMode)
    end
    -- A step under the Min in a fade to or from off is no level to hold: the
    -- light goes to the Min, or off under half way, the level alone.
    if ramp.sentBrightness and at and at < 1 and (ramp.startLevel == 0 or ramp.targetLevel == 0) then
      stoppedAt, at = range.placeLevel(ramp, at, range.offLevel())
      setESPHomeBrightness(stoppedAt, 0, true, at)
    end
    -- Otherwise nothing to cancel: the light is where the last step put it, in
    -- the color that step carried unless another was set since.
    local color = not keepColor and ramp.sentColor
    if color then
      notifyColorChanged(color.x, color.y, color.mode)
    elseif ramp.mergedColor then
      notifyColorChanged(currentColorX, currentColorY, currentColorMode)
    end
  else
    -- Cancel ESPHome's in-flight transition by sending a 0-transition cmd at
    -- the interpolated level. The bulb halts here.
    setESPHomeBrightness(stoppedAt, 0, keepColor, at)
  end
  notifyBrightnessChanged(stoppedAt)
end

local stopSceneSteps -- defined with the scene support below

--- Where the color a brightness ramp carries has got to on its way from the
--- color the light was in: the fade the proxy is told of.
--- @return number x, number y, integer mode, boolean done
local function carriedColor(ramp)
  local merged = ramp.mergedColor
  local progress = math.min(1, (C4:GetTime() - ramp.startTime) / ramp.durationMs)
  local x = currentColorX + (merged.x - currentColorX) * progress
  local y = currentColorY + (merged.y - currentColorY) * progress
  return x, y, merged.mode, progress >= 1
end

-- Leave the color a brightness ramp carries where the ramp has got to: what
-- replaces it starts there.
local function leaveMergedColor()
  local merged = brightnessRamp and brightnessRamp.mergedColor
  if merged then
    local x, y, mode = carriedColor(brightnessRamp)
    if fades == "Driver" then
      -- The light is in the color its last step carried, or still in its own.
      local sent = brightnessRamp.sentColor or { x = currentColorX, y = currentColorY, mode = currentColorMode }
      x, y, mode = sent.x, sent.y, sent.mode
    end
    currentColorX, currentColorY, currentColorMode = x, y, mode
    brightnessRamp.mergedColor = nil
    if fades == "Driver" then
      -- A walk goes on to its color, but one up from off has it with its levels.
      if brightnessRamp.startLevel > 0 then
        x, y, mode = merged.x, merged.y, merged.mode
      end
      carry.color(x, y, mode, brightnessRamp.startTime + brightnessRamp.durationMs - C4:GetTime())
    end
  end
end

-- End a brightness ramp where it has got to, so its replacement starts
-- there. Returns the ramp and the light's out-of-range line position.
local function leaveBrightnessRamp()
  local ramp = rampingBrightness and brightnessRamp or nil
  local outside = nil
  if rampingBrightness then
    local at
    at, outside = interpolatedBrightness()
    if at == 0 and currentBrightness > 0 then
      endOnCycle() -- a fade retargeted as it reaches off ends its on cycle
    end
    currentBrightness = at
    leaveMergedColor()
  elseif supportsDimming then
    outside = range.outsideAt(lightBrightness or 0)
  end
  cancelBrightnessRampTimers()
  rampingBrightness = false
  brightnessRamp = nil
  return ramp, outside
end

local function awayFromFadeColor(level)
  local fade = level > 0 and getColorOnModeKind() == COLOR_ON_MODE_FADE and computeFadeColor(level)
  if not fade or not buildColorCmdFields(fade.x, fade.y, fade.mode) then
    return false
  end
  local x, y, mode = currentColorX, currentColorY, currentColorMode
  if colorRamp then
    x, y, mode = colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode
  end
  return not sameColor(x, y, mode, fade.x, fade.y, fade.mode)
end

--- @param replaced table|nil A ramp the caller already ended for this one.
local function rampToBrightness(level, rate, presetId, replaced)
  level = math.max(0, math.min(100, math.floor((level or 0) + 0.5)))
  rate = math.max(0, tointeger(rate) or 0)

  log:debug("rampToBrightness(%s, %s) from %s", level, rate, currentBrightness)

  stopSceneSteps()

  -- Single source of truth for the active brightness preset id. SET_BRIGHTNESS_
  -- TARGET passes the proxy's id through; everywhere else (buttons, scenes,
  -- lightOn, etc.) omits it so the id clears and CHANGED notifies don't echo
  -- a stale value to the Daylight Agent.
  currentBrightnessPresetId = presetId

  local left, startAt = leaveBrightnessRamp()
  if replaced and not left then
    startAt = replaced.startAt -- a click starts where its press's ramp did
  end
  replaced = left or replaced

  local startingLevel = currentBrightness
  -- A light outside the range is not at the level it shows: it ramps there.
  if level == startingLevel and not startAt then
    -- Sent where the bulb is on its way to a replaced ramp's target, outside a
    -- range with no width, or with Dim-To-Warm in a color set since: the
    -- level's own color goes with it.
    if replaced or range.outsideRange(lightBrightness or 0) or awayFromFadeColor(level) then
      setESPHomeBrightness(level, 0)
    end
    notifyBrightnessChanged(level)
    return
  end

  rate = fadeTime(rate, startingLevel, level)
  if rate == 0 then
    setESPHomeBrightness(level, 0)
    notifyBrightnessChanged(level)
    return
  end

  rampingBrightness = true
  brightnessRamp = {
    startTime = C4:GetTime(),
    startLevel = startingLevel,
    startAt = startAt,
    targetLevel = level,
    from = range.endBrightness(startingLevel, startAt),
    to = range.toDevice(level),
    durationMs = rate,
  }
  -- Single ESPHome command - the bulb handles the physical transition.
  setESPHomeBrightness(level, rate)
  notifyBrightnessChanging(level, rate)
  -- Nothing is sent at the end: the light has held the level as its state
  -- since the command, and one sent again is one more request to answer.
  SetTimer("BrightnessRampFinish", rate, function()
    brightnessRampFinished(level)
  end, false)
end

---------------------------------------------------------------------------
-- Helpers: color ramping
---------------------------------------------------------------------------
-- Same shape as brightness ramping: send a single ESPHome light_command with
-- transition_length = rateMs so the bulb interpolates the physical color, and
-- track the logical color locally via a startTime/duration ramp record.

local function cancelColorRampTimers()
  CancelTimer("ColorRampFinish")
end

-- Build and send an ESPHome light_command reflecting the given color state.
--- @param on boolean? Whether the light is to be on, if not as it is now.
local function sendColor(x, y, mode, rateMs, on)
  if not (supportsColor or supportsCCT) then
    return
  end
  -- isLogicallyOn so that a SET_COLOR_TARGET arriving mid-ramp from off→on
  -- doesn't send state=false (which would cancel the brightness transition).
  if on == nil then
    on = isLogicallyOn()
  end
  local cmd = { has_state = true, state = on }
  if mode == LIGHT_COLOR_MODE_CCT and supportsCCT then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if k and k > 0 then
      cmd.has_color_temperature = true
      cmd.color_temperature = kelvinToMireds(k)
    end
  elseif supportsColor then
    local r, g, b = xyToRGB(x, y)
    cmd.has_rgb = true
    cmd.red = r
    cmd.green = g
    cmd.blue = b
  end
  cmd.has_transition_length = true
  cmd.transition_length = (rateMs and rateMs > 0) and rateMs or 0
  sendLightCommand(cmd)
end

--- @param line boolean? The color the ramp's line is at, which a step follows.
local function interpolatedColor(line)
  if not colorRamp or colorRamp.durationMs <= 0 then
    return currentColorX, currentColorY, currentColorMode
  end
  if fades == "Driver" and not line then
    return colorRamp.sentX or colorRamp.startX, colorRamp.sentY or colorRamp.startY, colorRamp.targetMode
  end
  local elapsed = C4:GetTime() - colorRamp.startTime
  if elapsed <= 0 then
    return colorRamp.startX, colorRamp.startY, colorRamp.targetMode
  end
  if elapsed >= colorRamp.durationMs then
    return colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode
  end
  local progress = elapsed / colorRamp.durationMs
  local x = colorRamp.startX + (colorRamp.targetX - colorRamp.startX) * progress
  local y = colorRamp.startY + (colorRamp.targetY - colorRamp.startY) * progress
  return x, y, colorRamp.targetMode
end

-- End a color ramp where it has got to: what replaces it starts there.
function leaveColorRamp()
  currentColorX, currentColorY, currentColorMode = interpolatedColor()
  cancelColorRampTimers()
  rampingColor = false
  colorRamp = nil
end

local function colorRampFinished(targetX, targetY, targetMode)
  cancelColorRampTimers()
  -- One told at an off went out with the preset id the off then dropped.
  local told = colorRamp and colorRamp.told
  if fades == "Driver" and rampingColor then
    -- The last step, as a level ramp's.
    colorRamp.startTime = C4:GetTime() - colorRamp.durationMs
    backendFade(true)
  end
  rampingColor = false
  colorRamp = nil
  if not told then
    notifyColorChanged(targetX, targetY, targetMode)
  end
end

local function colorRampStopped()
  if fades == "Light" then
    return
  end
  cancelColorRampTimers()
  if not rampingColor then
    return
  end
  local x, y, mode = interpolatedColor()
  rampingColor = false
  colorRamp = nil
  -- A light the driver walks is in the color of its last step: nothing to cancel.
  if fades ~= "Driver" then
    sendColor(x, y, mode, 0)
  end
  currentColorX = x
  currentColorY = y
  currentColorMode = mode
  notifyColorChanged(x, y, mode)
end

--- Walk the light on from the color it is in to one a replaced fade carried,
--- over `ms`; with no time left, send it and tell it at once.
--- @param on boolean? Whether the light is to be on, if not as it is now.
function carry.color(x, y, mode, ms, on)
  if ms <= 0 then
    if x ~= currentColorX or y ~= currentColorY then
      sendColor(x, y, mode, 0, on)
    end
    notifyColorChanged(x, y, mode)
    return
  end
  rampingColor = true
  colorRamp = {
    startTime = C4:GetTime(),
    startX = currentColorX,
    startY = currentColorY,
    targetX = x,
    targetY = y,
    targetMode = mode,
    durationMs = ms,
    carried = true,
  }
  SetTimer("ColorRampFinish", ms, function()
    colorRampFinished(x, y, mode)
  end, false)
end

--- A command with no color moves a carried one on over its own time, as an
--- ESPHome light runs one transition for every channel.
--- @param on boolean Whether the command leaves the light on.
function carry.retime(ms, on)
  local ramp = colorRamp
  if not (ramp and ramp.carried) then
    return
  end
  leaveColorRamp()
  -- One the light is in already has arrived.
  if ramp.targetX == currentColorX and ramp.targetY == currentColorY then
    ms = 0
  end
  carry.color(ramp.targetX, ramp.targetY, ramp.targetMode, ms, on)
  if rampingColor then
    notifyColorChanging(ramp.targetX, ramp.targetY, ramp.targetMode, ms)
  end
end

--- A command with no color turns the light back on while a walk told at an off
--- goes on: tell the rest of it, from where it has got to, and its end.
function carry.resume()
  local ramp = rampingColor and colorRamp
  if not (ramp and ramp.told) then
    return
  end
  local left = ramp.startTime + ramp.durationMs - C4:GetTime()
  if left > 0 then
    ramp.told = false
    currentColorX, currentColorY, currentColorMode = interpolatedColor(true)
    notifyColorChanging(ramp.targetX, ramp.targetY, ramp.targetMode, left)
  end
end

local function rampToColor(targetX, targetY, targetMode, rate)
  local lit = isLogicallyOn() and 1 or 0
  rate = fadeTime(math.max(0, tointeger(rate) or 0), lit, lit)

  -- Drop the on color a brightness ramp carries, or its end would report it.
  leaveMergedColor()
  leaveColorRamp()
  -- A stop of that ramp keeps this color, whether or not it carried one.
  if brightnessRamp then
    brightnessRamp.colorSet = true
  end

  if rate == 0 then
    currentColorX = targetX
    currentColorY = targetY
    currentColorMode = targetMode
    sendColor(targetX, targetY, targetMode, 0)
    notifyColorChanged(targetX, targetY, targetMode)
    return
  end

  rampingColor = true
  colorRamp = {
    startTime = C4:GetTime(),
    startX = currentColorX,
    startY = currentColorY,
    targetX = targetX,
    targetY = targetY,
    targetMode = targetMode,
    durationMs = rate,
  }
  sendColor(targetX, targetY, targetMode, rate)
  notifyColorChanging(targetX, targetY, targetMode, rate)
  -- Mode change is logically instantaneous; mid-ramp we're interpolating XY.
  currentColorMode = targetMode
  SetTimer("ColorRampFinish", rate, function()
    colorRampFinished(targetX, targetY, targetMode)
  end, false)
end

---------------------------------------------------------------------------
-- Helpers: a fade the driver makes itself
---------------------------------------------------------------------------
-- A light that takes no fade time from a command is walked along the ramps
-- above: sent where they have got to, a step at a time, as fast as it answers.

--- Whether a step is to name a color: it is no longer the one last sent, or
--- the fade ends on it and it has not been sent itself.
local function colorDue(x, y, mode, sentX, sentY, last)
  return not sameColor(x, y, mode, sentX, sentY, mode) or (last and (x ~= sentX or y ~= sentY))
end

--- The next step of the ramps in flight, with no fade time: the level and the
--- color each has got to, named only once it has moved on from the last sent.
--- @return table? cmd nil while neither has moved on.
local function rampStep()
  local cmd = {}
  local ramp = rampingBrightness and brightnessRamp
  local level, percent
  if ramp then
    level, percent = range.walk(ramp)
  end
  if ramp and percent ~= range.wholePercent(ramp.sentBrightness or ramp.from) then
    ramp.sentBrightness = percent / 100
    lightBrightness = ramp.sentBrightness
    cmd.has_state, cmd.state = true, percent > 0
    cmd.has_brightness, cmd.brightness = true, ramp.sentBrightness
  end
  -- The color the ramp carries. A light that is on is walked to it from the
  -- color it has, as the proxy is told. One coming on from off has none to
  -- walk from: the color goes with its levels, with Dim-To-Warm each one's own.
  local color, last = nil, false
  if ramp and not rampingColor and not ramp.colorSet then
    if ramp.startLevel == 0 and level > 0 then
      color = getColorOnModeKind() == COLOR_ON_MODE_FADE and computeFadeColor(level) or ramp.mergedColor
      last = level == ramp.targetLevel
    elseif ramp.startLevel > 0 and ramp.mergedColor then
      local x, y, mode
      x, y, mode, last = carriedColor(ramp)
      x, y, mode = takenColor(x, y, mode)
      color = { x = x, y = y, mode = mode }
    end
  end
  local sent = ramp and ramp.sentColor or { x = currentColorX, y = currentColorY }
  local fields = color and buildColorCmdFields(color.x, color.y, color.mode)
  if fields and colorDue(color.x, color.y, color.mode, sent.x, sent.y, last) then
    ramp.sentColor = color
    for k, v in pairs(fields) do
      cmd[k] = v
    end
    -- With an on: a color alone is kept for the light's next on.
    cmd.has_state, cmd.state = true, true
  end
  ramp = rampingColor and colorRamp
  -- An off goes alone: a color beside it is kept for the next on, and the off
  -- would be kept with it.
  if ramp and cmd.state ~= false then
    local x, y, mode = interpolatedColor(true)
    local last = C4:GetTime() - ramp.startTime >= ramp.durationMs
    local fields = buildColorCmdFields(x, y, mode)
    if fields and colorDue(x, y, mode, ramp.sentX or ramp.startX, ramp.sentY or ramp.startY, last) then
      ramp.sentX, ramp.sentY = x, y
      for k, v in pairs(fields) do
        cmd[k] = v
      end
      cmd.has_state, cmd.state = true, isLogicallyOn()
    end
  end
  if next(cmd) == nil then
    return nil
  end
  cmd.has_transition_length, cmd.transition_length = true, 0
  return cmd
end

---------------------------------------------------------------------------
-- Helpers: on / off / toggle
---------------------------------------------------------------------------

-- An On/Off-only light switches at once, replacing a ramp in flight.
local function switchLight(on)
  stopSceneSteps()
  cancelBrightnessRampTimers()
  rampingBrightness = false
  brightnessRamp = nil
  sendLightCommand({ has_state = true, state = on })
  notifyBrightnessChanged(on and 100 or 0)
end

local function lightOn(rate)
  local level = getOnBrightness()
  if not supportsDimming then
    switchLight(true)
    return
  end
  -- color_on_mode_previous/preset/fade are all handled by the merged-color
  -- path inside setESPHomeBrightness (via resolveOnColor on goingOn) so the
  -- color rides on the brightness transition as a single ESPHome cmd. Don't
  -- pre-send a separate color cmd here; that would queue two commands and
  -- the second would cancel and restart the in-flight transition.
  rampToBrightness(level, rate or 0)
end

local function lightOff(rate)
  if supportsDimming then
    rampToBrightness(0, rate or 0)
  else
    switchLight(false)
  end
end

local function lightToggle(rate)
  if interpolatedBrightness(true) > 0 then
    lightOff(rate)
  else
    lightOn(rate)
  end
end

---------------------------------------------------------------------------
-- RFP: LIGHT_V2 proxy commands
---------------------------------------------------------------------------

function RFP.SET_BRIGHTNESS_TARGET(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BRIGHTNESS_TARGET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = tonumber(Select(tParams, "LIGHT_BRIGHTNESS_TARGET")) or 0
  local rate = tointeger(Select(tParams, "RATE")) or getDefaultRate()
  -- spec _2.1: optional LIGHT_BRIGHTNESS_TARGET_PRESET_ID identifies the
  -- preset (e.g. Daylight Agent) driving this target. Pass it through so
  -- subsequent LIGHT_BRIGHTNESS_CHANGED notifies report it as the current
  -- preset id; other rampToBrightness call sites omit it and clear the id.
  local presetId = tointeger(Select(tParams, "LIGHT_BRIGHTNESS_TARGET_PRESET_ID"))
  rampToBrightness(level, rate, presetId)
end

function RFP.ON(idBinding, strCommand, tParams, args)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOn()
end

function RFP.OFF(idBinding, strCommand, tParams, args)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOff()
end

function RFP.TOGGLE(idBinding, strCommand, tParams, args)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightToggle()
end

-- DYNAMIC_ON / DYNAMIC_OFF (spec _1.3 / _1.2): O.S. 3.3.2+ Navigators send
-- these instead of plain ON/OFF for generic on/off interactions, allowing
-- the proxy to apply on-mode behavior (color fade, previous color, etc.).
-- We treat them identically to ON / OFF since lightOn/lightOff already
-- consult on-mode state.
function RFP.DYNAMIC_ON(idBinding, strCommand, tParams, args)
  log:trace("RFP.DYNAMIC_ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOn()
end

function RFP.DYNAMIC_OFF(idBinding, strCommand, tParams, args)
  log:trace("RFP.DYNAMIC_OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOff()
end

function RFP.SET_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = tointeger(Select(tParams, "LEVEL")) or 0
  if supportsDimming then
    rampToBrightness(level, 0)
  elseif level > 0 then
    lightOn()
  else
    lightOff()
  end
end

-- Legacy command, retained for compatibility with older Composer programming
-- and Alexa Voice Scenes (other LIGHT_V2 drivers carry the same forwarder).
function RFP.RAMP_TO_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.RAMP_TO_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  RFP.SET_BRIGHTNESS_TARGET(idBinding, "SET_BRIGHTNESS_TARGET", {
    LIGHT_BRIGHTNESS_TARGET = Select(tParams, "LEVEL"),
    RATE = Select(tParams, "TIME"),
  })
end

function RFP.SET_COLOR_TARGET(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COLOR_TARGET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end

  local kelvin = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE"))
  local x = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_X"))
  local y = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_Y"))
  local incomingMode = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_MODE"))
  local rate = tointeger(
    Select(tParams, "LIGHT_COLOR_TARGET_COLOR_RATE")
      or Select(tParams, "LIGHT_COLOR_TARGET_RATE")
      or Select(tParams, "RATE")
  ) or getDefaultColorRate()

  -- spec _3.1: if the proxy named a color preset and didn't pass explicit
  -- coordinates, look the preset up locally so the bulb still receives
  -- concrete values. Track the preset id either way so subsequent
  -- LIGHT_COLOR_CHANGED notifies report it as the current preset.
  local presetId = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ID"))
  if presetId ~= nil and not (x and y) and not (kelvin and kelvin > 0) then
    local preset = persist:get(P_COLOR_PRESETS, {})[tostring(presetId)]
    if preset then
      x = preset.x
      y = preset.y
      incomingMode = preset.mode
    else
      log:warn("SET_COLOR_TARGET: unknown LIGHT_COLOR_TARGET_PRESET_ID=%s", presetId)
      return
    end
  end
  currentColorPresetId = presetId

  local targetX, targetY, targetMode

  if kelvin and kelvin > 0 and supportsCCT then
    targetX, targetY = C4:ColorCCTtoXY(clampKelvin(kelvin))
    targetMode = LIGHT_COLOR_MODE_CCT
  elseif incomingMode == LIGHT_COLOR_MODE_CCT and supportsCCT and x and y then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if not k or k <= 0 then
      log:warn("SET_COLOR_TARGET: ColorXYtoCCT(%s, %s) returned %s", x, y, tostring(k))
      return
    end
    targetX, targetY, targetMode = takenColor(x, y, LIGHT_COLOR_MODE_CCT)
  elseif x and y and supportsColor then
    targetX, targetY, targetMode = x, y, LIGHT_COLOR_MODE_FULL
  else
    log:warn(
      "SET_COLOR_TARGET ignored (kelvin=%s x=%s y=%s mode=%s color=%s cct=%s)",
      tostring(kelvin),
      tostring(x),
      tostring(y),
      tostring(incomingMode),
      tostring(supportsColor),
      tostring(supportsCCT)
    )
    return
  end

  -- Skip the ESPHome cmd if a SET_BRIGHTNESS_TARGET right before us already
  -- merged this color into the brightness ramp cmd. Otherwise we'd send a
  -- second cmd to ESPHome that cancels and restarts the in-flight transition,
  -- making the brightness fade-up snap visually. The earlier merged-color
  -- path already emitted notifyColorChanging, and brightnessRampFinished
  -- will emit notifyColorChanged when the ramp completes - so there is
  -- nothing to notify here, just suppress the redundant ESPHome cmd.
  local now = C4:GetTime()
  local merged = rampingBrightness and brightnessRamp and brightnessRamp.mergedColor
  if now < mergedColorUntil and merged and sameColor(merged.x, merged.y, merged.mode, targetX, targetY, targetMode) then
    log:debug("SET_COLOR_TARGET deduped (%sms remaining in merged-color window)", mergedColorUntil - now)
    brightnessRamp.mergedColor = { x = targetX, y = targetY, mode = targetMode }
    return
  end

  rampToColor(targetX, targetY, targetMode, rate)
end

-- Halt an in-flight brightness transition at the current stepped level.
function RFP.SET_BRIGHTNESS_STOP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BRIGHTNESS_STOP(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  stopSceneSteps()
  brightnessRampStopped()
end

-- Re-read the level through the new range without moving the light; a ramp
-- in flight is re-read at its end.
function range.remap()
  if not supportsDimming then
    return
  end
  local ramp = rampingBrightness and brightnessRamp
  if ramp then
    -- The ramp's device brightnesses stay; only their levels move.
    ramp.startLevel, ramp.startAt = range.readLevel(ramp.from), range.outsideAt(ramp.from)
    ramp.targetLevel, ramp.targetAt = range.readLevel(ramp.to), range.outsideAt(ramp.to)
    currentBrightness = ramp.startLevel
    SetTimer("BrightnessRampFinish", math.max(1, ramp.startTime + ramp.durationMs - C4:GetTime()), function()
      brightnessRampFinished(ramp.targetLevel)
    end, false)
    return
  end
  local level = range.shownLevel(lightBrightness or 0)
  if not range.sameLevel(level, currentBrightness) then
    notifyBrightnessChanged(level)
  end
end

-- Spec _4 / _5: levels sent and read back are remapped through this range
-- (range.bounds); the echo keeps the proxy and Composer in step.
function RFP.SET_MAX_ON_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_MAX_ON_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 100))
  persist:set(P_MAX_ON_LEVEL, level)
  SendToProxy(PROXY_BINDING, "MAX_ON", tostring(level), "NOTIFY")
  range.remap()
end

function RFP.SET_MIN_ON_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_MIN_ON_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 0))
  persist:set(P_MIN_ON_LEVEL, level)
  SendToProxy(PROXY_BINDING, "MIN_ON", tostring(level), "NOTIFY")
  range.remap()
end

-- Halt an in-flight color transition at the current stepped XY/mode.
function RFP.SET_COLOR_STOP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COLOR_STOP(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  colorRampStopped()
end

function RFP.GET_CONNECTED_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_CONNECTED_STATE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = STATE ~= nil }, "NOTIFY")
end

-- Legacy: re-emit the current brightness when the proxy asks. Modern callers
-- read the cached BRIGHTNESS_PERCENT variable, but the LIGHT_V2 contract
-- includes this command for compatibility.
function RFP.GET_LIGHT_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_LIGHT_LEVEL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  if rampingBrightness then
    -- A CHANGED level is one the light has stopped at: in a ramp, say where it
    -- has got to and what is left.
    local left = brightnessRamp.startTime + brightnessRamp.durationMs - C4:GetTime()
    notifyBrightnessChanging(brightnessRamp.targetLevel, math.max(0, left), (interpolatedBrightness()))
    return
  end
  notifyBrightnessChanged(currentBrightness)
end

---------------------------------------------------------------------------
-- Scene support (Advanced Lighting Scenes)
---------------------------------------------------------------------------

local function getScenes()
  return persist:get(P_SCENES, {})
end

local function saveScenes(scenes)
  persist:set(P_SCENES, scenes)
end

-- Parse the LIGHT_V2 scene <element> XML. The proxy passes a string of one or
-- more <element>...</element> blocks describing what to do at each step.
-- Returns an array of normalized step tables.
local function parseSceneElements(elementsXml)
  local steps = {}
  if IsEmpty(elementsXml) then
    return steps
  end
  local parsed = ParseXml("<root>" .. elementsXml .. "</root>")
  local elementList = Select(parsed, "root", "element") or {}
  if not IsList(elementList) then
    elementList = { elementList }
  end
  for _, el in ipairs(elementList) do
    if type(el) == "table" then
      local rawBrightnessEnabled = Select(el, "brightnessEnabled")
      local rawColorEnabled = Select(el, "colorEnabled")
      local step = {
        delay = tointeger(Select(el, "delay")) or 0,
        brightnessRate = tointeger(Select(el, "brightnessRate") or Select(el, "rate")) or 0,
        colorRate = tointeger(Select(el, "colorRate")) or 0,
        level = tointeger(Select(el, "brightness") or Select(el, "level")),
        levelEnabled = toboolean(rawBrightnessEnabled),
        colorEnabled = toboolean(rawColorEnabled),
        colorX = tonumber(Select(el, "colorX")),
        colorY = tonumber(Select(el, "colorY")),
        colorMode = tointeger(Select(el, "colorMode")),
      }
      -- Legacy schemas put <level> at the element root with no <brightnessEnabled>
      -- wrapper. Only promote when the wrapper is truly absent, not when it's
      -- explicitly false (toboolean collapses nil and "false" to the same value).
      if rawBrightnessEnabled == nil and rawColorEnabled == nil and step.level ~= nil then
        step.levelEnabled = true
      end
      if step.colorRate == 0 and step.brightnessRate > 0 then
        step.colorRate = step.brightnessRate
      end
      if step.levelEnabled or step.colorEnabled or step.delay > 0 then
        table.insert(steps, step)
      end
    end
  end
  log:debug("parseSceneElements: %d step(s) parsed", #steps)
  return steps
end

-- Bumped any time we want to invalidate in-flight scene step callbacks. The
-- timer names alone don't always prevent a callback already queued by SetTimer
-- from running, so each step closure captures the generation it was born under
-- and bails out if it has changed.
local sceneGeneration = 0

-- A level command takes the light out of a scene, as on Control4's own
-- lights: no later step runs. The step in flight still ends its own ramps.
function stopSceneSteps()
  sceneGeneration = sceneGeneration + 1
end

local function stopAllScenes()
  sceneGeneration = sceneGeneration + 1
  CancelTimer(SCENE_RAMP_TIMER)
  local scenes = getScenes()
  for sceneId, _ in pairs(scenes) do
    CancelTimer(SCENE_TIMER_PREFIX .. tostring(sceneId))
  end
  -- A ramp in flight is left to run, as the bulb does: its own timer ends it.
end

local function applySceneStep(step)
  -- Build one combined light_command so the device transitions atomically when
  -- both brightness and color change in the same step.
  if not step.levelEnabled and not step.colorEnabled then
    return 0
  end
  local cmd = {}
  -- ESPHome takes a single transition_length per cmd, so the bulb interpolates
  -- both brightness and color over the longer of the two requested rates. Use
  -- that unified rate for ramp metadata and notify payloads so the proxy's
  -- picker animation, the local STOP-mid-step interpolation, and the SCENE_
  -- TIMER all agree on when the transition actually completes.
  local rate = math.max(step.brightnessRate or 0, step.colorRate or 0)
  -- How long the step's fade takes. The scene goes on after the step's own
  -- rate, whatever a light that fades by itself takes over it.
  local lit = isLogicallyOn() and 1 or 0
  local fade = fadeTime(rate, lit, lit)
  local startTime = C4:GetTime()
  -- A level of 0 means "off"; the color block is metadata for the next on.
  -- Don't send color/RGB fields in that case so the device actually turns off.
  local turningOff = step.levelEnabled and step.level == 0
  local replaced = nil
  -- A color ramp, or the color a brightness ramp carries, that the proxy has
  -- been told is on its way.
  local colorInFlight = rampingColor or (brightnessRamp and brightnessRamp.mergedColor)
  local goingOn = false
  local level = nil
  if step.levelEnabled and step.level ~= nil then
    level = supportsDimming and step.level or (step.level > 0 and 100 or 0)
    cmd.has_state = true
    cmd.state = step.level > 0
    if step.level > 0 and supportsDimming then
      cmd.has_brightness = true
      cmd.brightness = range.toDevice(step.level)
    end
    -- Scene step is driving brightness directly; clear any active preset id
    -- so subsequent CHANGED notifies don't echo a stale value. Color-only
    -- steps don't touch this so a brightness preset can survive across them.
    currentBrightnessPresetId = nil
    -- A color-only step leaves a brightness ramp running, as the bulb does:
    -- only a level replaces it.
    local startAt
    replaced, startAt = leaveBrightnessRamp()
    fade = fadeTime(rate, currentBrightness, level)
    goingOn = level > 0 and currentBrightness == 0
    -- Only prime a ramp when the level actually moves (or the light is outside
    -- the range); an explicit step at the current level with rate>0 would
    -- otherwise queue a pointless picker animation and suppress the next echo
    -- for no reason.
    if supportsDimming and fade > 0 and (level ~= currentBrightness or startAt) then
      rampingBrightness = true
      brightnessRamp = {
        startTime = startTime,
        startLevel = currentBrightness,
        startAt = startAt,
        targetLevel = level,
        from = range.endBrightness(currentBrightness, startAt),
        to = range.toDevice(level),
        durationMs = fade,
        step = step,
      }
      notifyBrightnessChanging(level, fade)
      -- Ends the ramp when the scene is stopped before the step's timer does.
      SetTimer("BrightnessRampFinish", fade, function()
        brightnessRampFinished(level)
      end, false)
    end
  end
  local color = nil
  if step.colorEnabled and step.colorX and step.colorY then
    local x, y, mode = takenColor(step.colorX, step.colorY, step.colorMode or LIGHT_COLOR_MODE_FULL)
    color = { x = x, y = y, mode = mode }
  end
  local ownColor = color
  -- A step that sets a level alone takes the color a level command would.
  if not color and (level or 0) > 0 then
    if getColorOnModeKind() == COLOR_ON_MODE_FADE then
      color = computeFadeColor(step.level)
    elseif goingOn then
      color = resolveOnColor(step.level)
    end
  end
  local colorAtOnce = nil
  if color and not turningOff then
    -- The step's color replaces the on color a brightness ramp carries and a
    -- color ramp in flight, each from where it has got to.
    leaveMergedColor()
    leaveColorRamp()
    -- A stop keeps a color of the step's own, as it keeps a color command's.
    if ownColor and brightnessRamp then
      brightnessRamp.colorSet = true
    end
    local mode = color.mode or LIGHT_COLOR_MODE_FULL
    if mode == LIGHT_COLOR_MODE_CCT and supportsCCT then
      local k = tonumber(C4:ColorXYtoCCT(color.x, color.y))
      if k and k > 0 then
        cmd.has_color_temperature = true
        cmd.color_temperature = kelvinToMireds(k)
      end
    elseif supportsColor then
      local r, g, b = xyToRGB(color.x, color.y)
      cmd.has_rgb = true
      cmd.red = r
      cmd.green = g
      cmd.blue = b
    end
    cmd.has_state = true
    cmd.state = true
    currentColorPresetId = nil
    local colorChanged = math.abs(color.x - currentColorX) > 1e-4
      or math.abs(color.y - currentColorY) > 1e-4
      or mode ~= currentColorMode
    -- A light the driver walks up from off has no color to fade from: it
    -- comes on in the step's.
    local fromOff = fades == "Driver" and currentBrightness == 0
    if fade > 0 and colorChanged and not fromOff then
      rampingColor = true
      colorRamp = {
        startTime = startTime,
        startX = currentColorX,
        startY = currentColorY,
        targetX = color.x,
        targetY = color.y,
        targetMode = mode,
        durationMs = fade,
        step = step,
      }
      notifyColorChanging(color.x, color.y, mode, fade)
      SetTimer("ColorRampFinish", fade, function()
        colorRampFinished(color.x, color.y, mode)
      end, false)
    elseif colorChanged or colorInFlight then
      colorAtOnce = { x = color.x, y = color.y, mode = mode }
    end
  end
  if next(cmd) ~= nil then
    -- A rate of 0 is sent too, as setESPHomeBrightness sends it.
    cmd.has_transition_length = true
    cmd.transition_length = rate
    if goingOn and rate > 0 and supportsDimming then
      sendPreOn()
    end
    sendLightCommand(cmd)
    carry.retime(fade, cmd.state ~= false)
    if goingOn then
      carry.resume()
    end
    -- A step taken at once is where the light is: what follows starts there.
    -- One landing where a replaced ramp had got to is told too, as its end.
    if level ~= nil and not rampingBrightness and (level ~= currentBrightness or replaced) then
      notifyBrightnessChanged(level)
    end
    if colorAtOnce then
      notifyColorChanged(colorAtOnce.x, colorAtOnce.y, colorAtOnce.mode)
    end
  end
  return rate
end

local function runScene(sceneId, generation)
  if generation ~= nil and generation ~= sceneGeneration then
    return
  end
  local gen = generation or sceneGeneration
  local scenes = getScenes()
  local scene = scenes[tostring(sceneId)]
  if not scene then
    log:warn("Scene %s not found", sceneId)
    return
  end
  scene.state = scene.state or 0
  local timerName = SCENE_TIMER_PREFIX .. tostring(sceneId)
  CancelTimer(timerName)

  -- Steps run here without waiting: a flash scene with no delay or rate on
  -- any step ends after one pass, where it would otherwise loop forever.
  local ran = 0
  while true do
    if gen ~= sceneGeneration then
      return
    end
    local idx = scene.state + 1
    if idx > #scene.elements then
      if scene.flash and ran < #scene.elements then
        scene.state = 0
        idx = 1
      else
        scene.state = 0
        scenes[tostring(sceneId)] = scene
        saveScenes(scenes)
        return
      end
    end
    local step = scene.elements[idx]
    local delay = math.max(0, step.delay or 0)
    scene.state = idx
    scenes[tostring(sceneId)] = scene
    saveScenes(scenes)

    -- At the step's end, finish the ramps it primed so their CHANGED notifies
    -- come before the next step. A ramp it did not prime is left alone.
    local function advanceAfter(rampMs)
      local level = brightnessRamp and brightnessRamp.step == step and brightnessRamp
      local color = colorRamp and colorRamp.step == step and colorRamp
      SetTimer(timerName, rampMs, function()
        if level and brightnessRamp == level then
          brightnessRampFinished(level.targetLevel)
        end
        if color and colorRamp == color then
          colorRampFinished(color.targetX, color.targetY, color.targetMode)
        end
        runScene(sceneId, gen)
      end)
    end

    if delay > 0 then
      SetTimer(timerName, delay, function()
        if gen ~= sceneGeneration then
          return
        end
        local rampMs = applySceneStep(step)
        if rampMs > 0 then
          advanceAfter(rampMs)
        else
          runScene(sceneId, gen)
        end
      end)
      return
    end

    local rampMs = applySceneStep(step)
    if rampMs > 0 then
      advanceAfter(rampMs)
      return
    end
    -- otherwise loop synchronously to the next element
    ran = ran + 1
  end
end

function RFP.PUSH_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.PUSH_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  local elements = Select(tParams, "ELEMENTS")
  local scenes = getScenes()
  scenes[tostring(sceneId)] = {
    elements = parseSceneElements(elements),
    flash = toboolean(Select(tParams, "FLASH")),
    ignoreRamp = toboolean(Select(tParams, "IGNORE_RAMP")),
    fromGroup = toboolean(Select(tParams, "FROM_GROUP")),
    state = 0,
  }
  saveScenes(scenes)
  log:debug("Stored scene %s with %d element(s)", sceneId, #scenes[tostring(sceneId)].elements)
end

function RFP.REMOVE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.REMOVE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  CancelTimer(SCENE_TIMER_PREFIX .. tostring(sceneId))
  local scenes = getScenes()
  scenes[tostring(sceneId)] = nil
  saveScenes(scenes)
end

function RFP.CLEAR_ALL_SCENES(idBinding, strCommand, tParams, args)
  log:trace("RFP.CLEAR_ALL_SCENES(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  stopAllScenes()
  saveScenes({})
end

function RFP.ALL_SCENES_PUSHED(idBinding, strCommand, tParams, args)
  log:trace("RFP.ALL_SCENES_PUSHED(%s, %s)", idBinding, strCommand)
  -- Marker that the proxy has finished pushing scenes; nothing to do.
end

function RFP.ACTIVATE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.ACTIVATE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  stopAllScenes()
  local scenes = getScenes()
  local scene = scenes[tostring(sceneId)]
  if not scene then
    log:warn("ACTIVATE_SCENE: unknown scene id %s", sceneId)
    return
  end
  scene.state = 0
  scenes[tostring(sceneId)] = scene
  saveScenes(scenes)
  runScene(sceneId)
end

function RFP.DEACTIVATE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.DEACTIVATE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- The Advanced Lighting agent uses DEACTIVATE_SCENE to mark a scene "off"
  -- in its own bookkeeping. Our driver doesn't track which scene is currently
  -- "active" (the device just reflects the last commands sent), so we just
  -- stop any running scene playback.
  stopAllScenes()
end

function RFP.RAMP_SCENE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.RAMP_SCENE_UP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local rate = tointeger(Select(tParams, "RATE")) or 0
  local scenes = getScenes()
  local scene = sceneId and scenes[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  stopAllScenes()
  if supportsDimming then
    rampToBrightness(getOnBrightness(), rate)
  else
    lightOn()
  end
end

function RFP.RAMP_SCENE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.RAMP_SCENE_DOWN(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local rate = tointeger(Select(tParams, "RATE")) or 0
  local scenes = getScenes()
  local scene = sceneId and scenes[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  stopAllScenes()
  if supportsDimming then
    rampToBrightness(0, rate)
  else
    lightOff()
  end
end

function RFP.STOP_SCENE_RAMP(idBinding, strCommand, tParams, args)
  log:trace("RFP.STOP_SCENE_RAMP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local scenes = getScenes()
  local scene = sceneId and scenes[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  brightnessRampStopped()
  colorRampStopped()
  stopAllScenes()
end

-- The published spec calls this command STOP_RAMP_SCENE; older / template code
-- uses STOP_SCENE_RAMP. Register both so the proxy can reach us either way.
RFP.STOP_RAMP_SCENE = RFP.STOP_SCENE_RAMP

function RFP.TOGGLE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.TOGGLE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- We don't track per-scene "active" state on the device side, so we always
  -- activate the requested scene. The agent's own bookkeeping handles toggle
  -- semantics across the project.
  RFP.ACTIVATE_SCENE(idBinding, "ACTIVATE_SCENE", tParams)
end

---------------------------------------------------------------------------
-- RFP: preset and rate management
---------------------------------------------------------------------------

function RFP.SET_PRESET_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_PRESET_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = tointeger(Select(tParams, "LEVEL")) or DEFAULT_PRESET_LEVEL
  persist:set(P_PRESET_LEVEL, level)
  -- PRESET_LEVEL notify takes a single BRIGHTNESS value (1-100) as a plain
  -- string, not a parameter map. Sending it as {BRIGHTNESS=N} causes the
  -- proxy to reject the value and revert the preset to 0 - blocking users
  -- from changing the Default On level in Composer.
  SendToProxy(PROXY_BINDING, "PRESET_LEVEL", tostring(level), "NOTIFY")
end

function RFP.UPDATE_BRIGHTNESS_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local presetId = tointeger(Select(tParams, "BRIGHTNESS_PRESET_ID"))
  local presetLevel = tonumber(Select(tParams, "BRIGHTNESS_PRESET_LEVEL")) or DEFAULT_PRESET_LEVEL
  persist:set(P_ON_MODE, { id = presetId, level = presetLevel })
  -- The preset whose edits the on level follows, as UPDATE_BRIGHTNESS_PRESET
  -- brings them.
  persist:set(P_BRIGHTNESS_ON_MODE_PRESET, presetId)
end

-- Per spec _21.2: SET_BRIGHTNESS_ON_MODE is sent by the proxy to tell the
-- driver which preset ID should be used as the "On" target. When the proxy
-- isn't the initiator (button link, scene), we use this to know what level
-- to ramp to.
function RFP.SET_BRIGHTNESS_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BRIGHTNESS_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local presetId = tointeger(Select(tParams, "PRESET_ID"))
  if presetId == nil then
    return
  end
  persist:set(P_BRIGHTNESS_ON_MODE_PRESET, presetId)
  -- Look up the preset's current level so getOnBrightness uses it immediately.
  local presets = persist:get(P_BRIGHTNESS_PRESETS, {})
  local preset = presets[tostring(presetId)]
  if preset and preset.level then
    persist:set(P_ON_MODE, { id = presetId, level = preset.level })
  end
end

function RFP.UPDATE_BRIGHTNESS_PRESET(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_PRESET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local command = Select(tParams, "COMMAND")
  local presetId = tointeger(Select(tParams, "ID"))
  local level = tonumber(Select(tParams, "LEVEL"))
  local name = Select(tParams, "NAME")
  if presetId == nil then
    return
  end
  local presets = persist:get(P_BRIGHTNESS_PRESETS, {})
  local key = tostring(presetId)
  if command == "REMOVED" then
    presets[key] = nil
  else
    presets[key] = { id = presetId, name = name, level = level }
  end
  persist:set(P_BRIGHTNESS_PRESETS, presets)
  -- If this preset is the currently-active on-mode preset, refresh the
  -- on-mode level so getOnBrightness picks up the change immediately.
  local activeId = tointeger(persist:get(P_BRIGHTNESS_ON_MODE_PRESET))
  if activeId ~= nil and activeId == presetId then
    if level == nil then
      persist:delete(P_ON_MODE)
    else
      persist:set(P_ON_MODE, { id = presetId, level = level })
    end
  end
end

-- color_rate_behavior=1: brightness and color share a single default rate.
-- Composer's "Default Brightness and Color Rate" only sets one value; we
-- persist both keys to the same rate so the two getters can't drift.
function RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(P_RATE_DEFAULT, rate)
  persist:set(P_COLOR_RATE_DEFAULT, rate)
end

function RFP.UPDATE_COLOR_RATE_DEFAULT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_RATE_DEFAULT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(P_COLOR_RATE_DEFAULT, rate)
  persist:set(P_RATE_DEFAULT, rate)
end

-- Persist color presets keyed by ID so we can apply them when the proxy is
-- not the initiator (button link, scene, programming, dim-to-warm fade).
function RFP.UPDATE_COLOR_PRESET(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_PRESET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local command = Select(tParams, "COMMAND")
  local presetId = tointeger(Select(tParams, "ID"))
  if presetId == nil then
    return
  end
  local presets = persist:get(P_COLOR_PRESETS, {})
  local key = tostring(presetId)
  if command == "REMOVED" then
    presets[key] = nil
  else
    presets[key] = {
      id = presetId,
      name = Select(tParams, "NAME"),
      x = tonumber(Select(tParams, "COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_MODE")),
    }
  end
  persist:set(P_COLOR_PRESETS, presets)
  -- The on and dim colors follow an edit of the preset the on mode names.
  local onMode = persist:get(P_COLOR_ON_MODE, {})
  if onMode.onPreset and presets[key] then
    for _, p in ipairs({ onMode.onPreset, onMode.fadePreset }) do
      if p.id == presetId and p.origin == PRESET_ORIGIN_DEVICE then
        p.x, p.y, p.mode = presets[key].x, presets[key].y, presets[key].mode
      end
    end
    persist:set(P_COLOR_ON_MODE, onMode)
  end
end

-- Per spec _20.4: UPDATE_COLOR_ON_MODE carries the active On preset (and a
-- separate Fade pair for Dim-To-Warm). We persist both so we can drive color
-- ourselves on non-proxy on actions and apply the fade formula.
function RFP.UPDATE_COLOR_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local mode = {
    onPreset = {
      id = tointeger(Select(tParams, "COLOR_PRESET_ID")),
      origin = tointeger(Select(tParams, "COLOR_PRESET_ORIGIN")),
      x = tonumber(Select(tParams, "COLOR_PRESET_COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_PRESET_COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_PRESET_COLOR_MODE")),
    },
    fadePreset = {
      id = tointeger(Select(tParams, "COLOR_FADE_PRESET_ID")),
      origin = tointeger(Select(tParams, "COLOR_FADE_PRESET_ORIGIN")),
      x = tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_FADE_PRESET_COLOR_MODE")),
    },
  }
  persist:set(P_COLOR_ON_MODE, mode)
end

-- SET_COLOR_ON_MODE (spec _9.1): proxy tells the driver which mode is active
-- (preset / fade / previous). We persist the mode kind so we can branch in
-- lightOn and brightness handling.
function RFP.SET_COLOR_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COLOR_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local presetId = tointeger(Select(tParams, "PRESET_ID"))
  persist:set(P_COLOR_ON_MODE_PRESET, presetId)
end

-- Click/hold rate echo notifies follow the same convention as PRESET_LEVEL:
-- the proxy expects a plain string with the rate value, not a parameter map.
-- Sending {RATE=N} causes the proxy to reject the value and revert the
-- setting to 0, which is why Composer keeps showing 0 after a save.
function RFP.SET_CLICK_RATE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_CLICK_RATE_UP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_CLICK_RATE
  persist:set(P_CLICK_RATE_UP, rate)
  SendToProxy(PROXY_BINDING, "CLICK_RATE_UP", tostring(rate), "NOTIFY")
end

function RFP.SET_CLICK_RATE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_CLICK_RATE_DOWN(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_CLICK_RATE
  persist:set(P_CLICK_RATE_DOWN, rate)
  SendToProxy(PROXY_BINDING, "CLICK_RATE_DOWN", tostring(rate), "NOTIFY")
end

function RFP.SET_HOLD_RATE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_HOLD_RATE_UP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_HOLD_RATE
  persist:set(P_HOLD_RATE_UP, rate)
  SendToProxy(PROXY_BINDING, "HOLD_RATE_UP", tostring(rate), "NOTIFY")
end

function RFP.SET_HOLD_RATE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_HOLD_RATE_DOWN(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_HOLD_RATE
  persist:set(P_HOLD_RATE_DOWN, rate)
  SendToProxy(PROXY_BINDING, "HOLD_RATE_DOWN", tostring(rate), "NOTIFY")
end

---------------------------------------------------------------------------
-- RFP: button colors
---------------------------------------------------------------------------

function RFP.REQUEST_BUTTON_COLORS(idBinding, strCommand, tParams, args)
  log:trace("RFP.REQUEST_BUTTON_COLORS(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  for _, buttonId in ipairs({ 0, 1, 2 }) do
    local onColor, offColor = getButtonColors(buttonId)
    SendToProxy(PROXY_BINDING, "BUTTON_COLORS", {
      BUTTON_ID = buttonId,
      ON_COLOR = onColor,
      OFF_COLOR = offColor,
    }, "NOTIFY")
  end
  -- MATCH_LED_STATE per button binding, with bottom inverted (its LED lights
  -- when the light is off so the keypad shows the toggle state correctly).
  local isOn = ledState
  SendToProxy(ON_BINDING, "MATCH_LED_STATE", { STATE = isOn }, "NOTIFY", true)
  SendToProxy(OFF_BINDING, "MATCH_LED_STATE", { STATE = not isOn }, "NOTIFY", true)
  SendToProxy(TOGGLE_BINDING, "MATCH_LED_STATE", { STATE = isOn }, "NOTIFY", true)
end

function RFP.SET_BUTTON_COLOR(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BUTTON_COLOR(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local onColor = Select(tParams, "ON_COLOR")
  local offColor = Select(tParams, "OFF_COLOR")
  if buttonId == nil then
    return
  end
  setButtonColors(buttonId, onColor, offColor)
  if onColor then
    SendToProxy(PROXY_BINDING, "BUTTON_INFO", { BUTTON_ID = buttonId, ON_COLOR = onColor }, "NOTIFY")
  end
  if offColor then
    SendToProxy(PROXY_BINDING, "BUTTON_INFO", { BUTTON_ID = buttonId, OFF_COLOR = offColor }, "NOTIFY")
  end
end

---------------------------------------------------------------------------
-- RFP: button actions (from proxy)
---------------------------------------------------------------------------

-- The level a click acts on, and its press's hold ramp, dropped here so the
-- click starts from the level the press found. No press: where the light is.
local function rewindToPrePress()
  local snapshot = prePressBrightness
  prePressBrightness = nil
  if snapshot == nil then
    return (interpolatedBrightness(true))
  end
  local hold = rampingBrightness and brightnessRamp or nil
  cancelBrightnessRampTimers()
  rampingBrightness = false
  brightnessRamp = nil
  return snapshot, hold
end

-- Shared button-action implementation. Used by RFP.BUTTON_ACTION (proxy ->
-- driver path, e.g. on-device buttons or programming) and by DO_CLICK /
-- DO_PUSH / DO_RELEASE (button-link path, e.g. a keypad button bound to one
-- of our BUTTON_LINK connections). Returns nothing.
local function handleButtonAction(buttonId, action)
  if action == constants.ButtonActions.PRESS then
    -- Button-down. Snapshot brightness for the click race, then start a hold
    -- ramp at the persisted hold rate. If the proxy decides this was a click,
    -- a RELEASE_CLICK will arrive ~110ms later and the click's ramp starts
    -- from this snapshot.
    -- currentBrightness lags a ramp in flight, so take the light's own level.
    prePressBrightness = interpolatedBrightness(true)
    if not supportsDimming then
      if buttonId == constants.ButtonIds.TOP then
        lightOn()
      elseif buttonId == constants.ButtonIds.BOTTOM then
        lightOff()
      elseif buttonId == constants.ButtonIds.TOGGLE then
        lightToggle()
      end
      return
    end
    -- A hold ramps to full or off until released; a click, to the on level.
    if buttonId == constants.ButtonIds.TOP then
      rampToBrightness(100, getHoldRateUp())
    elseif buttonId == constants.ButtonIds.BOTTOM then
      rampToBrightness(0, getHoldRateDown())
    elseif buttonId == constants.ButtonIds.TOGGLE then
      if prePressBrightness > 0 then
        rampToBrightness(0, getHoldRateDown())
      else
        rampToBrightness(100, getHoldRateUp())
      end
    end
  elseif action == constants.ButtonActions.RELEASE_HOLD then
    prePressBrightness = nil
    brightnessRampStopped()
  elseif action == constants.ButtonActions.RELEASE_CLICK then
    local effective, hold = rewindToPrePress()
    if buttonId == constants.ButtonIds.TOP then
      if supportsDimming then
        rampToBrightness(getOnBrightness(), getClickRateUp(), nil, hold)
      else
        lightOn()
      end
    elseif buttonId == constants.ButtonIds.BOTTOM then
      if supportsDimming then
        rampToBrightness(0, getClickRateDown(), nil, hold)
      else
        lightOff()
      end
    elseif buttonId == constants.ButtonIds.TOGGLE then
      if supportsDimming then
        if effective > 0 then
          rampToBrightness(0, getClickRateDown(), nil, hold)
        else
          rampToBrightness(getOnBrightness(), getClickRateUp(), nil, hold)
        end
      else
        if effective > 0 then
          lightOff()
        else
          lightOn()
        end
      end
    end
  end
end

function RFP.BUTTON_ACTION(idBinding, strCommand, tParams, args)
  log:trace("RFP.BUTTON_ACTION(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end

  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local action = tointeger(Select(tParams, "ACTION"))

  handleButtonAction(buttonId, action)

  -- Echo the button action AFTER the ramp setup. If we send this BEFORE the
  -- LIGHT_BRIGHTNESS_CHANGING notify, the proxy treats it as a state-change
  -- event and snaps the UI to the on/off target, then our CHANGING repositions
  -- back to current and animates - producing a visible jump-and-rewind.
  SendToProxy(PROXY_BINDING, "BUTTON_ACTION", {
    BUTTON_ID = buttonId,
    ACTION = action,
  }, "NOTIFY")
end

---------------------------------------------------------------------------
-- RFP: button link bindings (DO_CLICK, DO_PUSH, DO_RELEASE)
---------------------------------------------------------------------------

local function buttonIdFromBinding(idBinding)
  if idBinding == ON_BINDING then
    return constants.ButtonIds.TOP
  elseif idBinding == OFF_BINDING then
    return constants.ButtonIds.BOTTOM
  elseif idBinding == TOGGLE_BINDING then
    return constants.ButtonIds.TOGGLE
  end
  return nil
end

-- Button-link bindings forward to handleButtonAction directly. Unlike the
-- proxy-initiated BUTTON_ACTION path, we don't send a BUTTON_ACTION echo
-- back to the proxy here: the proxy is the one that sent us DO_*, so it
-- already knows the button fired. Echoing would make the proxy snap the UI
-- to the on/off target before our LIGHT_BRIGHTNESS_CHANGING animates.
function RFP.DO_CLICK(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_CLICK(%s, %s)", idBinding, strCommand)
  local buttonId = buttonIdFromBinding(idBinding)
  if buttonId == nil then
    return
  end
  handleButtonAction(buttonId, constants.ButtonActions.RELEASE_CLICK)
end

function RFP.DO_PUSH(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_PUSH(%s, %s)", idBinding, strCommand)
  local buttonId = buttonIdFromBinding(idBinding)
  if buttonId == nil then
    return
  end
  handleButtonAction(buttonId, constants.ButtonActions.PRESS)
end

function RFP.DO_RELEASE(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_RELEASE(%s, %s)", idBinding, strCommand)
  local buttonId = buttonIdFromBinding(idBinding)
  if buttonId == nil then
    return
  end
  handleButtonAction(buttonId, constants.ButtonActions.RELEASE_HOLD)
end

---------------------------------------------------------------------------
-- RFP: ESPHome state updates
---------------------------------------------------------------------------

local function handleDisconnect()
  cancelBrightnessRampTimers()
  cancelColorRampTimers()
  rampingBrightness = false
  rampingColor = false
  brightnessRamp = nil
  colorRamp = nil
  stopAllScenes()
  ENTITY = nil
  STATE = nil
  dynamicCapsSent = false
  supportsDimming = false
  supportsColor = false
  supportsCCT = false
  supportedColorModes = {}
  currentBrightness = 0
  ledState = false
  prePressBrightness = nil
  mergedColorUntil = 0
  currentBrightnessPresetId = nil
  currentColorPresetId = nil
  lightBrightness = nil
  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  notifyBrightnessChanged(0)
end

function RFP.UPDATE_DISCONNECT(idBinding, strCommand)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s)", idBinding, strCommand)
  if idBinding ~= OUTLET_BINDING then
    return
  end
  handleDisconnect()
end

--- @param news boolean? The light is not where the driver sent it: another
---   hand has moved it, so a ramp in flight is over and this is where it is.
local function applyUpdate(entity, state, news)
  log:trace("applyUpdate(%s, %s)", entity, state)

  local wasConnected = STATE ~= nil
  local isFirstUpdate = ENTITY == nil
  ENTITY = entity
  STATE = state

  local levelNews = news and rampingBrightness
  local colorNews = news and (rampingColor or (brightnessRamp and brightnessRamp.mergedColor))
  if news then
    cancelBrightnessRampTimers()
    cancelColorRampTimers()
    rampingBrightness, rampingColor, brightnessRamp, colorRamp = false, false, nil, nil
    -- As a level command does: no later step of a scene moves the light on.
    if levelNews or colorNews then
      stopSceneSteps()
    end
  end

  -- Connection state must be sent BEFORE dynamic capabilities
  if not wasConnected then
    UpdateProperty("Driver Status", transportName and ("Connected (" .. transportName .. ")") or "Connected")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
  end

  -- Send dynamic capabilities after ONLINE_CHANGED
  if isFirstUpdate then
    updateDynamicCapabilities(entity)
  end

  -- A first report is held against the proxy's Brightness Percent and Current Color Chromaticity ("x,y,mode"), unless
  -- a ramp left it another target: it fires Brightness or Color Changed for any other value it is told.
  local levelShown, colorShown = not isFirstUpdate, not isFirstUpdate
  if isFirstUpdate then
    local ok, level, levelTarget, color, colorTarget = pcall(function()
      local proxy = C4:GetProxyDevices()
      return C4:GetDeviceVariable(proxy, 1001),
        C4:GetDeviceVariable(proxy, 1110),
        C4:GetDeviceVariable(proxy, 1200),
        C4:GetDeviceVariable(proxy, 1210)
    end)
    level = ok and tointeger(level)
    if level and level >= 0 and level <= 100 then
      currentBrightness, levelShown = level, tointeger(levelTarget) == level
    end
    local x, y, mode = string.match(ok and tostring(color or "") or "", "^([^,]+),([^,]+),([^,]+)$")
    x, y, mode = tonumber(x), tonumber(y), tointeger(mode)
    if x and y and x + y > 0 and (mode == LIGHT_COLOR_MODE_FULL or mode == LIGHT_COLOR_MODE_CCT) then
      currentColorX, currentColorY, currentColorMode, colorShown = x, y, mode, colorTarget == color
    end
  end

  -- Map ESPHome brightness (0.0-1.0) to C4 (0-100) through the on-level range
  local newBrightness
  local brightness = 0
  local isOn = Select(state, "state") or false
  if not isOn then
    newBrightness = 0
  elseif supportsDimming then
    brightness = tofinite(Select(state, "brightness")) or 1.0
    newBrightness = math.max(1, range.shownLevel(brightness))
  else
    brightness = 1.0
    newBrightness = 100
  end
  lightBrightness = brightness

  -- During a ramp, ESPHome's echo confirms the target value (not the
  -- interpolated physical value), so we ignore it - rampingBrightness will
  -- be cleared in brightnessRampFinished or brightnessRampStopped, both of
  -- which set currentBrightness to the appropriate value before the snap
  -- cmd's echo can arrive. Outside a ramp, the echo's target equals what
  -- we last set, so processing it is a no-op (newBrightness already
  -- matches currentBrightness).
  if rampingBrightness then
    log:trace("UPDATE_STATE brightness=%s ignored (ramping)", newBrightness)
  elseif not levelShown or levelNews or not range.sameLevel(newBrightness, currentBrightness) then
    notifyBrightnessChanged(newBrightness)
  elseif isFirstUpdate then
    matchLedState(currentBrightness > 0)
  end

  -- A light keeps its color while off, so read it whether or not it is lit.
  -- A ramp tells its own color, or the one it carries, at its end.
  local merged = rampingBrightness and brightnessRamp and brightnessRamp.mergedColor
  if (supportsColor or supportsCCT) and not rampingColor and not merged then
    local activeMode = tointeger(Select(state, "color_mode"))
    local newX, newY, newColorMode
    if activeMode and COLOR_MODES_SUPPORTING_CCT[activeMode] and Select(state, "color_temperature") then
      local mireds = tonumber(Select(state, "color_temperature"))
      if mireds and mireds > 0 then
        local k = miredsToKelvin(mireds)
        newX, newY = C4:ColorCCTtoXY(k)
        newColorMode = LIGHT_COLOR_MODE_CCT
      end
    elseif activeMode and COLOR_MODES_SUPPORTING_RGB[activeMode] then
      local r = tonumber(Select(state, "red")) or 0
      local g = tonumber(Select(state, "green")) or 0
      local b = tonumber(Select(state, "blue")) or 0
      if r > 0 or g > 0 or b > 0 then
        local h, s = rgbToHSV(r, g, b)
        newX, newY = C4:ColorHSVtoXY(h, s, 100)
        newColorMode = LIGHT_COLOR_MODE_FULL
      end
    end
    -- Threshold matches xy round-trip drift through RGB / HSV (typically
    -- 1-2e-3 in either coordinate). Tighter than this fires spurious notifies
    -- and clears the active preset id when the bulb just echoes our own cmd
    -- back. Looser than ~1e-2 starts missing visible changes.
    local COLOR_ECHO_TOLERANCE = 5e-3
    if
      newX
      and newY
      and newColorMode
      and (
        not colorShown
        or colorNews
        or math.abs(newX - currentColorX) > COLOR_ECHO_TOLERANCE
        or math.abs(newY - currentColorY) > COLOR_ECHO_TOLERANCE
        or newColorMode ~= currentColorMode
      )
    then
      -- Hardware-driven color change (out-of-band update): no preset is
      -- driving this, so don't echo a stale preset id.
      currentColorPresetId = nil
      notifyColorChanged(newX, newY, newColorMode)
    end
  end
end

function RFP.UPDATE_STATE(idBinding, strCommand, tParams)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= OUTLET_BINDING then
    log:error("RFP.UPDATE_STATE called with idBinding %s, expected %s", idBinding, OUTLET_BINDING)
    return
  end
  local entity = DeserializeSafe(Select(tParams, "entity"))
  local state = DeserializeSafe(Select(tParams, "state"))
  if IsEmpty(entity) or IsEmpty(state) then
    log:error("RFP.UPDATE_STATE called with invalid parameters: %s", tParams)
    return
  end
  applyUpdate(entity, state)
end

---------------------------------------------------------------------------
-- Binding change
---------------------------------------------------------------------------

OBC[OUTLET_BINDING] = function()
  ENTITY = nil
  STATE = nil
  dynamicCapsSent = false
  supportsDimming = false
  supportsColor = false
  supportsCCT = false
  supportedColorModes = {}
  currentBrightness = 0
  ledState = false
  rampingBrightness = false
  rampingColor = false
  brightnessRamp = nil
  colorRamp = nil
  prePressBrightness = nil
  mergedColorUntil = 0
  currentBrightnessPresetId = nil
  currentColorPresetId = nil
  lightBrightness = nil
  currentColorX = DEFAULT_COLOR_X
  currentColorY = DEFAULT_COLOR_Y
  currentColorMode = LIGHT_COLOR_MODE_CCT
  cancelBrightnessRampTimers()
  cancelColorRampTimers()
  stopAllScenes()
  if gInitialized then
    backendStart()
  end
end

---------------------------------------------------------------------------
-- Backends
---------------------------------------------------------------------------
-- Two ways to reach a light:
--   Proxy mode: the OUTLET_BINDING is bound to a tplink_outlet output. The
--     outlet driver pushes UPDATE_STATE / UPDATE_DISCONNECT and executes
--     ENTITY_COMMAND, using the same message contract as the internal
--     applyUpdate path.
--   Direct mode: the IP Address and TP-Link credential properties point at
--     a light device (e.g. Tapo L930) speaking the SMART schema over KLAP.
-- The bound outlet wins; network properties are hidden while bound.

local DIRECT_POLL_TIMER = "DirectPoll"

--- Whether the outlet binding is currently connected.
--- @return boolean
local function isOutletBound()
  local provider = C4:GetBoundProviderDevice(C4:GetDeviceID(), OUTLET_BINDING)
  return provider ~= nil and provider ~= 0
end

--- Whether the direct-mode session believes the device is online.
--- @type boolean
local directConnected = false

--- Counts backendStart, as sceneGeneration counts scenes: a connect attempt,
--- and the answer to a poll or a command, does nothing once it has moved on.
--- @type number
local backendGeneration = 0

--- Whether a connect attempt is still probing. The poll timer's retry waits
--- for it: a start would replace it before it had found or failed to find.
--- @type boolean
local directDetecting = false

--- Map a SMART get_device_info result to the entity shape applyUpdate expects.
--- @param info table
--- @return table entity
local function synthesizeEntity(info)
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

--- Map a SMART get_device_info result to the state shape applyUpdate expects.
--- @param info table
--- @return table state
local function synthesizeState(info)
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

--- A direct-mode light serves one request at a time, and those in flight
--- together in an order of its own: one goes out, and the rest wait for it.
--- @type boolean
local directBusy = false

--- The command waiting for the request in flight, every later one merged in.
--- @type table?
local directWaiting = nil

--- Whether a poll waits for the request in flight.
--- @type boolean
local directPollWaiting = false

--- Counts the commands made. A poll sent before the latest reads the light as
--- it was before that command.
--- @type number
local directCommands = 0

--- The color a SMART light was given while off, which it would ignore. It is
--- held here and goes out with the next command that turns the light on.
--- @type table?
local smartPendingColor = nil

--- What a SMART light holds, as it was sent or read since the last command
--- from Control4: its state, its level and its color.
--- @type table?
local smartHeld = nil

--- Take a poll's answer as what the light holds.
--- @param info table
--- @return boolean moved Whether another hand has moved it: it is not what the
---   light held.
local function smartRead(info)
  local held = smartHeld or {}
  smartHeld = {
    device_on = toboolean(info.device_on),
    brightness = tonumber_locale(info.brightness),
    hue = tonumber_locale(info.hue),
    saturation = tonumber_locale(info.saturation),
    color_temp = tonumber_locale(info.color_temp),
  }
  local function moved(field)
    return held[field] ~= nil and held[field] ~= smartHeld[field]
  end
  if moved("device_on") or moved("brightness") or moved("color_temp") then
    return true
  end
  -- In a color temperature the light holds no hue of its own.
  return smartHeld.color_temp == 0 and (moved("hue") or moved("saturation"))
end

local directNext -- defined below, after what it sends

--- The least time between two steps of a fade, however fast the light answers,
--- and the wait to look again while nothing has moved on, in milliseconds.
--- @type number
local FADE_STEP_MS = 100

local FADE_STEP_TIMER = "FadeStep"

--- When the last step of a fade went out, by C4:GetTime().
--- @type number
local fadeStepAt = 0

--- How long a request in flight is waited for, in milliseconds: past the
--- transports' own timeouts, 10 s for a KLAP post and 5 s on the legacy port.
--- @type number
local DIRECT_ANSWER_MS = 15000

local DIRECT_ANSWER_TIMER = "DirectAnswer"

--- Put a request in flight, and send what waited for it once its answer or
--- its failure is in. One with neither after DIRECT_ANSWER_MS has failed: a
--- request its transport never settled would hold every later one.
--- @param request Deferred
--- @param onAnswer fun(response: table)
--- @param onFail fun(err: table)
local function directFlight(request, onAnswer, onFail)
  local generation = backendGeneration
  local over = false
  directBusy = true
  local function landed(handler)
    return function(value)
      if over or generation ~= backendGeneration then
        return
      end
      over = true
      CancelTimer(DIRECT_ANSWER_TIMER)
      directBusy = false
      handler(value)
      directNext()
    end
  end
  -- Set first: a request settled already lands inside next().
  SetTimer(DIRECT_ANSWER_TIMER, DIRECT_ANSWER_MS, function()
    landed(onFail)({ error = "no answer from the light" })
  end)
  request:next(landed(onAnswer), landed(onFail))
end

--- Poll the direct-mode device and feed the result into applyUpdate.
local function directPoll()
  if directBusy then
    directPollWaiting = true
    return
  end
  local asked = directCommands

  if directSchema == "iot" and iotBulb ~= nil then
    directFlight(iotBulb:poll(), function(result)
      directConnected = true
      if asked == directCommands then
        applyUpdate(result.entity, result.state)
      end
    end, function(err)
      log:warn("IOT bulb poll failed: %s", Select(err, "error") or err)
      if directConnected then
        directConnected = false
        handleDisconnect()
      end
      if Select(err, "code") == 403 then
        UpdateProperty("Driver Status", "Disconnected: " .. Select(err, "error"))
      end
    end)
    return
  end

  directFlight(klap:request({ method = "get_device_info", params = {} }), function(response)
    if tointeger(Select(response, "error_code")) ~= 0 then
      log:warn("get_device_info failed: %s", response)
      if directConnected then
        directConnected = false
        handleDisconnect()
      end
      return
    end
    local info = Select(response, "result") or {}
    -- A light that is back may be back with other fades of its own.
    ownFades.due = ownFades.due or not directConnected
    directConnected = true
    if asked == directCommands then
      local moved = smartRead(info)
      if toboolean(info.device_on) then
        -- Turned on by another hand, in the color it had.
        smartPendingColor = nil
      end
      -- The color held for a light that is off is the one it will come on in.
      for field, value in pairs(smartPendingColor or {}) do
        info[field] = value
      end
      applyUpdate(synthesizeEntity(info), synthesizeState(info), moved)
    end
  end, function(err)
    log:warn("get_device_info failed: %s", Select(err, "error") or err)
    if directConnected then
      directConnected = false
      handleDisconnect()
    end
    if Select(err, "code") == 403 then
      UpdateProperty("Driver Status", "Disconnected: " .. Select(err, "error"))
    end
  end)
end

--- Translate an internal light command (ESPHome light_command shape) to the
--- params of a SMART set_device_info request. A ramp rate the command carries
--- is not sent: the light takes no fade time from a command. A color for a
--- light that is off is held (smartPendingColor), and added to the next on.
--- @param opts table
--- @return table? params nil when the command names nothing to send.
local function smartParams(opts)
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
    local maxMireds = tonumber(Select(ENTITY or {}, "max_mireds"))
    local minMireds = tonumber(Select(ENTITY or {}, "min_mireds"))
    local kelvinMin = (maxMireds and maxMireds > 0) and math.floor(1e6 / maxMireds + 0.5) or 2500
    local kelvinMax = (minMireds and minMireds > 0) and math.floor(1e6 / minMireds + 0.5) or 6500
    params.color_temp = math.max(kelvinMin, math.min(kelvinMax, kelvin))
  elseif opts.has_rgb then
    local h, sat = rgbToHSV(tonumber(opts.red) or 0, tonumber(opts.green) or 0, tonumber(opts.blue) or 0)
    params.hue = math.floor((h or 0) + 0.5) % 360
    params.saturation = math.max(0, math.min(100, math.floor((sat or 0) + 0.5)))
    params.color_temp = 0
  end
  local color = params.color_temp ~= nil
  -- No on with it: the light is off, or is being turned off.
  if color and not params.device_on then
    smartPendingColor = { hue = params.hue, saturation = params.saturation, color_temp = params.color_temp }
    params.hue, params.saturation, params.color_temp = nil, nil, nil
  elseif color then
    smartPendingColor = nil
  elseif params.device_on then
    for field, value in pairs(smartPendingColor or {}) do
      params[field] = value
    end
    smartPendingColor = nil
  end
  if IsEmpty(params) then
    return nil
  end
  return params
end

--- Send a light command to the direct-mode device now.
--- @param opts table
--- @return boolean sent false when the command names nothing to send.
local function directSend(opts)
  if directSchema == "iot" and iotBulb ~= nil then
    directFlight(iotBulb:execute(opts), function() end, function(err)
      -- Command failures are logged only; the poll loop decides connectivity.
      log:error("IOT bulb command failed: %s", Select(err, "error") or err)
    end)
    return true
  end

  local params = smartParams(opts)
  if params == nil then
    return false
  end
  smartHeld = smartHeld or {}
  for field, value in pairs(params) do
    smartHeld[field] = value
  end
  directFlight(klap:request({ method = "set_device_info", params = params }), function(response)
    local code = tointeger(Select(response, "error_code")) or -1
    if code ~= 0 then
      log:error("set_device_info failed: %s", response)
    end
  end, function(err)
    log:error("set_device_info failed: %s", Select(err, "error") or err)
    if directConnected then
      directConnected = false
      handleDisconnect()
    end
  end)
  return true
end

--- How long a light takes over its own fade between two states while it is
--- on, in milliseconds. It reports no length for it: measured on a Tapo strip.
--- @type number
local OWN_CHANGE_MS = 1000

--- Read the light's own fades and switch on each that is off, at the length it
--- has, which is the owner's. Then the proxy is told the rate that is fixed.
local function readOwnFades()
  local function tell()
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", rateCapabilities(), "NOTIFY", true)
  end
  local function failed(err)
    log:warn("The light's own fades could not be read or switched on: %s", Select(err, "error") or err)
    tell()
  end
  --- A fade's length in milliseconds, 0 for one that is off or not there.
  local function length(state, ms)
    return type(state) == "table" and toboolean(state.enable) and (ms or (tointeger(state.duration) or 0) * 1000) or 0
  end
  directFlight(klap:request({ method = "get_on_off_gradually_info", params = {} }), function(response)
    local info = Select(response, "result")
    if tointeger(Select(response, "error_code")) ~= 0 or type(info) ~= "table" then
      failed(response)
      return
    end
    -- An older light answers with one switch for all its fades and no length
    -- for them: it is switched on as the others are, and told as no fade.
    local one = info.enable ~= nil
    local names = one and { "all" } or { "on_state", "off_state", "change_state" }
    if one then
      info = { all = info }
    end
    --- Switch on the fades that are off, from the `i`th, a request each, and
    --- then take them all as they are.
    local function switchOn(i)
      local name = names[i]
      local state = info[name]
      if fades ~= "Light" then
        return
      end
      if name == nil then
        ownFades = {
          on = length(info.on_state),
          off = length(info.off_state),
          change = length(info.change_state, OWN_CHANGE_MS),
        }
        tell()
      elseif type(state) ~= "table" or toboolean(state.enable) then
        switchOn(i + 1)
      else
        local params = one and { enable = true } or { [name] = { enable = true, duration = state.duration } }
        directFlight(klap:request({ method = "set_on_off_gradually_info", params = params }), function(answer)
          state.enable = tointeger(Select(answer, "error_code")) == 0
          if not state.enable then
            failed(answer)
          end
          switchOn(i + 1)
        end, failed)
      end
    end
    switchOn(1)
  end, failed)
end

--- The light's own fades first when due, then the command, then the poll, which
--- so reads the light after it, then a fade's next step.
function directNext()
  -- An answer's handler may have put a request of its own in flight.
  if directBusy then
    return
  end
  if ownFades.due then
    ownFades.due = false
    if fades == "Light" then
      readOwnFades()
      return
    end
  end
  local waiting = directWaiting
  directWaiting = nil
  if waiting ~= nil and directSend(waiting) then
    return
  end
  if directPollWaiting then
    directPollWaiting = false
    directPoll()
  end
  backendFade()
end

--- The fields of a light command that name its color.
local COLOR_FIELDS = {
  "has_rgb",
  "red",
  "green",
  "blue",
  "has_color_temperature",
  "color_temperature",
  "has_color_mode",
  "color_mode",
  "has_cold_white",
  "cold_white",
  "has_warm_white",
  "warm_white",
}

--- Send a light command to the direct-mode device, or hold it while a request
--- is in flight. Commands held together go out as one, merged field by field
--- with the later value winning; a later color replaces an earlier one whole.
--- @param opts table
--- @param step boolean? A step of a fade the driver makes, not a new command.
local function directExecute(opts, step)
  -- A rated on's pre-on, an on at under 1 %, would go out as a bare on: the
  -- light would come up at the level it was last at, ahead of its fade.
  local level = opts.has_brightness and opts.state and math.floor((tonumber(opts.brightness) or 0) * 100 + 0.5)
  if level and level < 1 and not (opts.has_rgb or opts.has_color_temperature) then
    return
  end
  -- What the light held before a command may be another hand's, older than
  -- the command: a poll after it is news only against what it holds since.
  if fades and not step then
    smartHeld = nil
  end
  -- A fade the driver makes: the command is where it ends, and is not sent.
  -- The steps bring what a ramp walks, and only what is left goes at once.
  if fades == "Driver" and (tointeger(opts.transition_length) or 0) > 0 then
    if rampingBrightness then
      opts.has_brightness, opts.brightness = nil, nil
    end
    if rampingColor or (rampingBrightness and brightnessRamp.mergedColor) then
      for _, field in ipairs(COLOR_FIELDS) do
        opts[field] = nil
      end
    end
    local left = opts.has_brightness or opts.has_rgb or opts.has_color_temperature
    if (rampingBrightness or rampingColor) and not left then
      backendFade()
      return
    end
  end
  -- A color with no level turns on no light the driver has not. One it walks
  -- is as its last step left it, and one that fades by itself as it was sent.
  local color = opts.has_rgb or opts.has_color_temperature
  if fades and rampingBrightness and color and not opts.has_brightness then
    opts.state = (fades == "Driver" and interpolatedBrightness() or brightnessRamp.targetLevel) > 0
  end
  -- A color for a SMART light that is off is no off: a light turned on since
  -- is left on. It names no state here, so an off it waits with is still one.
  if directSchema ~= "iot" and opts.state == false and (opts.has_rgb or opts.has_color_temperature) then
    opts.has_state, opts.state = nil, nil
  end
  directCommands = directCommands + 1
  if not directBusy then
    directSend(opts)
    -- A command that sent nothing has no answer to bring a fade's next step.
    backendFade()
    return
  end
  if directWaiting == nil then
    directWaiting = opts
    return
  end
  if opts.has_rgb or opts.has_color_temperature then
    for _, field in ipairs(COLOR_FIELDS) do
      directWaiting[field] = nil
    end
  end
  for field, value in pairs(opts) do
    directWaiting[field] = value
  end
end

--- Send a fade's next step to a light free to take it. Its answer brings the
--- one after, so steps go as fast as it answers, no nearer than FADE_STEP_MS.
--- @param last boolean? The step is a ramp's last: it goes at the ramp's end,
---   and waits its turn if it must.
backendFade = function(last)
  if fades ~= "Driver" or (directBusy and not last) then
    return
  end
  local wait = last and 0 or fadeStepAt + FADE_STEP_MS - C4:GetTime()
  local step = wait <= 0 and rampStep() or nil
  if step ~= nil then
    fadeStepAt = C4:GetTime()
    directExecute(step, true)
  end
  if not directBusy and (rampingBrightness or rampingColor) then
    SetTimer(FADE_STEP_TIMER, wait > 0 and wait or FADE_STEP_MS, function()
      backendFade()
    end)
  end
end

--- Dispatch an internal light command to the active backend.
--- @param opts table
backendSendCommand = function(opts)
  if isOutletBound() then
    SendToProxy(OUTLET_BINDING, "ENTITY_COMMAND", {
      body = SerializeSafe(opts),
    })
  elseif not IsEmpty(Properties["IP Address"]) then
    directExecute(opts)
  else
    log:warn("Light command dropped: not bound to an outlet and no IP Address configured")
  end
end

--- Show or hide the direct-mode network properties.
--- @param attrib number constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
local function setNetworkPropertiesAttribs(attrib)
  C4:SetPropertyAttribs("TP-Link Settings", attrib)
  C4:SetPropertyAttribs("IP Address", attrib)
  C4:SetPropertyAttribs("Protocol", attrib)
  C4:SetPropertyAttribs("TP-Link Username", attrib)
  C4:SetPropertyAttribs("TP-Link Password", attrib)
  C4:SetPropertyAttribs("Poll Rate (Seconds)", attrib)
end

--- Select and start the appropriate backend from current bindings/properties.
--- @param retry boolean? The poll timer trying again after no light was found.
backendStart = function(retry)
  CancelTimer(DIRECT_POLL_TIMER)
  -- A fade the driver makes ends where its last step left the light, and is not
  -- taken up again: the first read after this tells the proxy where that is.
  if fades == "Driver" and (rampingBrightness or rampingColor) then
    leaveBrightnessRamp()
    leaveColorRamp()
    stopSceneSteps()
  end
  backendGeneration = backendGeneration + 1
  local generation = backendGeneration
  directDetecting = false
  directConnected = false
  transportName = nil
  -- The request in flight and what waited were for the backend as it was.
  directBusy = false
  directWaiting = nil
  directPollWaiting = false
  smartPendingColor = nil
  fades = nil
  ownFades = {}
  C4:SetPropertyAttribs("Fades", constants.HIDE_PROPERTY)

  -- Force a fresh capability discovery on every (re)connect. The light_v2
  -- proxy resets to the static baseline whenever the driver reloads, so the
  -- dynamic capabilities must be re-emitted; clearing ENTITY makes the next
  -- state update count as the first and re-run updateDynamicCapabilities.
  ENTITY = nil
  STATE = nil
  dynamicCapsSent = false
  supportsDimming = false
  supportsColor = false
  supportsCCT = false
  supportedColorModes = {}

  if isOutletBound() then
    transportName = "Outlet"
    setNetworkPropertiesAttribs(constants.HIDE_PROPERTY)
    SendToProxy(OUTLET_BINDING, "REFRESH_STATE", {}, "NOTIFY")
    return
  end

  setNetworkPropertiesAttribs(constants.SHOW_PROPERTY)
  directSchema = nil
  iotBulb = nil

  local ip = Properties["IP Address"] or ""
  if IsEmpty(ip) then
    UpdateProperty("Driver Status", "Bind to an outlet or set the IP Address property")
    return
  end

  local config = {
    ip = ip,
    username = Properties["TP-Link Username"] or "",
    password = Properties["TP-Link Password"] or "",
  }
  klap:configure(config)
  klapV1:configure(config)
  legacy:configure({ ip = ip })
  -- A probe the last attempt left on the legacy port would hold this one's.
  legacy:reset()

  local mode = Properties["Protocol"] or "Auto"
  local hasCredentials = not IsEmpty(Properties["TP-Link Username"]) and not IsEmpty(Properties["TP-Link Password"])

  --- A continuation of this attempt: one that comes in after the backend has
  --- been started again does nothing.
  --- @param continuation function
  --- @return function
  local function live(continuation)
    return function(...)
      if generation == backendGeneration then
        continuation(...)
      end
    end
  end

  --- Say which transport is being tried. A retry says nothing: the reason the
  --- last attempt failed for stays up until this one ends another way.
  --- @param name string
  local function connecting(name)
    if not retry then
      UpdateProperty("Driver Status", "Connecting (" .. name .. ")...")
    end
  end

  --- End this attempt with no light found. The poll timer tries again.
  --- @param reason string
  local function failed(reason)
    directDetecting = false
    UpdateProperty("Driver Status", "Disconnected: " .. reason)
  end

  --- Adopt a probed schema/transport and apply its first poll result.
  --- @param schema string "smart" or "iot"
  --- @param bulb IotBulb? The adapter, for the "iot" schema.
  --- @param name string Transport name for Driver Status.
  --- @param entity table
  --- @param state table
  local function adopt(schema, bulb, name, entity, state)
    directDetecting = false
    directSchema = schema
    iotBulb = bulb
    transportName = name
    directConnected = true
    -- A light on the SMART schema takes no fade time from a command, so who
    -- makes its fades is the installer's choice.
    if schema == "smart" then
      fades = Properties["Fades"] or "Driver"
      ownFades.due = true
      C4:SetPropertyAttribs("Fades", constants.SHOW_PROPERTY)
    end
    log:info("Using %s transport for direct control", name)
    applyUpdate(entity, state)
    -- Its own fades are read now, where Fades leaves the fades to the light.
    directNext()
  end

  --- Probe a transport with the IOT bulb schema.
  --- @param transport Legacy|Klap
  --- @param name string
  --- @param onFail fun(reason: string)
  local function tryIotBulb(transport, name, onFail)
    local bulb = IotBulb:new(transport)
    bulb:poll():next(
      live(function(result)
        adopt("iot", bulb, name, result.entity, result.state)
      end),
      live(function(err)
        onFail(Select(err, "error") or "no response")
      end)
    )
  end

  --- Probe the established KLAP v2 session with the SMART schema.
  --- @param onFail fun(reason: string)
  local function trySmart(onFail)
    klap:request({ method = "get_device_info", params = {} }):next(
      live(function(response)
        if tointeger(Select(response, "error_code")) == 0 then
          local info = Select(response, "result") or {}
          adopt("smart", nil, "SMART", synthesizeEntity(info), synthesizeState(info))
        else
          onFail("device rejected get_device_info over KLAP")
        end
      end),
      live(function(err)
        onFail(Select(err, "error") or "SMART request failed")
      end)
    )
  end

  --- Probe the legacy port 9999 transport, the last resort in Auto mode.
  --- @param klapReason string? The KLAP failure that led here, for the status.
  --- @param klapCode number? HTTP status of a refused KLAP handshake, if any.
  local function tryLegacy(klapReason, klapCode)
    connecting("Legacy")
    tryIotBulb(legacy, "Legacy", function(legacyReason)
      if klapCode == 403 then
        log:info("Legacy probe failed: %s", legacyReason)
        failed(klapReason)
        return
      end
      if mode == "Auto" and not hasCredentials then
        legacyReason = legacyReason .. " (set TP-Link credentials if this device is on KLAP firmware)"
      end
      failed(klapReason and ("KLAP: " .. klapReason .. " / Legacy: " .. legacyReason) or legacyReason)
    end)
  end

  --- Route a KLAP-side failure to legacy fallback or a final status.
  --- @param reason string
  --- @param code number? HTTP status of a refused handshake, if any.
  local function onKlapFail(reason, code)
    if mode == "KLAP" then
      failed(reason)
    else
      log:info("KLAP probe failed (%s); trying legacy protocol", reason)
      tryLegacy(reason, code)
    end
  end

  --- Probe the KLAP transports: v2 handshake, then the SMART schema (Tapo,
  --- newer Kasa), then the IOT bulb schema over the same session (KL-series
  --- on KLAP firmware). A v2 auth mismatch retries the handshake with v1
  --- hashing before falling back.
  local function tryKlap()
    connecting("KLAP")
    klap:connect():next(
      live(function()
        trySmart(function(smartReason)
          log:info("SMART probe failed (%s); trying IOT bulb schema over KLAP", smartReason)
          tryIotBulb(klap, "KLAP", onKlapFail)
        end)
      end),
      live(function(err)
        local reason = Select(err, "error") or "KLAP connection failed"
        if string.find(reason, "auth mismatch", 1, true) == nil then
          onKlapFail(reason, Select(err, "code"))
          return
        end
        log:info("KLAP v2 handshake failed (%s); retrying with v1 hashing", reason)
        klapV1:connect():next(
          live(function()
            tryIotBulb(klapV1, "KLAP", onKlapFail)
          end),
          live(function(v1Err)
            onKlapFail(Select(v1Err, "error") or "KLAP connection failed", Select(v1Err, "code"))
          end)
        )
      end)
    )
  end

  if mode == "KLAP" or (mode == "Auto" and hasCredentials) then
    if not hasCredentials then
      UpdateProperty("Driver Status", "Set the TP-Link Username and Password properties (required for KLAP)")
      return
    end
    directDetecting = true
    tryKlap()
  else
    -- Legacy mode, or Auto without credentials (KL-series bulbs on original
    -- firmware need none).
    directDetecting = true
    tryLegacy(nil)
  end

  local pollSeconds = tointeger(Properties["Poll Rate (Seconds)"]) or 5
  SetTimer(DIRECT_POLL_TIMER, pollSeconds * 1000, function()
    if directSchema ~= nil then
      directPoll()
    elseif not directDetecting then
      -- Detection found no light; keep retrying until the device answers.
      backendStart(true)
    end
  end, true)
end

---------------------------------------------------------------------------
-- Property handlers: direct mode
---------------------------------------------------------------------------

--- @param propertyValue string
function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  if gInitialized then
    backendStart()
  end
end

--- @param propertyValue string
function OPC.Protocol(propertyValue)
  log:trace("OPC.Protocol('%s')", propertyValue)
  if gInitialized then
    backendStart()
  end
end

--- Reconnect action: discard any established sessions and re-detect.
function EC.Reconnect()
  log:info("Action: Reconnect")
  klap:reset()
  klapV1:reset()
  legacy:reset()
  backendStart()
end

-- The handler library prints a property's value at Log Level "6 - Ultra".
OPC.suppressDebug["TP-Link Username"] = true
OPC.suppressDebug["TP-Link Password"] = true

--- Restart the backend for a changed credential. It must not raise: the
--- handler library prints the value of a property whose handler does.
local function credentialChanged()
  if not gInitialized then
    return
  end
  local ok, err = pcall(backendStart)
  if not ok then
    log:error("The backend did not start: %s", err)
  end
end

function OPC.TP_Link_Username()
  log:trace("OPC.TP_Link_Username(<redacted>)")
  credentialChanged()
end

function OPC.TP_Link_Password()
  log:trace("OPC.TP_Link_Password(<redacted>)")
  credentialChanged()
end

--- @param propertyValue string
function OPC.Poll_Rate_Seconds(propertyValue)
  log:trace("OPC.Poll_Rate_Seconds('%s')", propertyValue)
  if gInitialized then
    backendStart()
  end
end

--- @param propertyValue string
function OPC.Fades(propertyValue)
  log:trace("OPC.Fades('%s')", propertyValue)
  -- The choice is a connected light's, one on the SMART schema.
  if fades == nil or fades == propertyValue then
    return
  end
  -- A ramp in flight ends here, at its target.
  if rampingBrightness then
    brightnessRampFinished(brightnessRamp.targetLevel)
  end
  if rampingColor then
    colorRampFinished(colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode)
  end
  fades = propertyValue
  -- For Light the proxy is told once the light's own fades are read.
  if fades == "Driver" and dynamicCapsSent then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", rateCapabilities(), "NOTIFY", true)
  end
  ownFades.due = true
  directNext()
end
