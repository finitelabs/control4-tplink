--- The TP-Link Light's own code beneath the light library, with the light reached directly over KLAP, TPAP or
--- the legacy port: how the driver finds the light and finds it again, what waits behind a request in flight,
--- what a Kasa bulb is sent for a rate, the strip's own fades under Fades set to Light, the properties and log
--- lines it shows, the timers it leaves, and what its removal leaves.
---
--- Driven through the driver's entry points on a virtual clock, with
--- SendToProxy captured. The transports are stand-ins that hold every reply
--- until the test gives it, as a light that takes its time does.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_tplink_light_driver.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local Caps = require("lib.light.caps")
local Light = require("lib.light")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/tplink_light/driver.lua"

local PROXY = 5001

---------------------------------------------------------------------------
-- Virtual clock: the poll timer repeats, and a reply takes the time the test
-- gives it.
---------------------------------------------------------------------------

local now = 1000000
local queue, order = {}, 0

--- Each timer's entry in the queue, by the handle it was given.
local entries = setmetatable({}, { __mode = "k" })

function C4:GetTime()
  return now
end

function C4:SetTimer(delayMs, callback, repeating)
  order = order + 1
  local t = { at = now + delayMs, order = order }
  local handle = newproxy(true)
  entries[handle] = t
  getmetatable(handle).__index = {
    Cancel = function()
      t.cancelled = true
    end,
  }
  t.fn = function()
    if repeating then
      order = order + 1
      t.at, t.order = now + delayMs, order
      queue[#queue + 1] = t
    end
    callback(handle, 0)
  end
  queue[#queue + 1] = t
  return handle
end

--- Run everything due within the next `ms`, in the order it falls due.
local function run(ms)
  local stop = now + ms
  while true do
    local best, bi
    for i, t in ipairs(queue) do
      if
        not t.cancelled
        and t.at <= stop
        and (not best or t.at < best.at or (t.at == best.at and t.order < best.order))
      then
        best, bi = t, i
      end
    end
    if not best then
      break
    end
    table.remove(queue, bi)
    now = best.at
    best.fn()
  end
  now = stop
end

--- The names of the driver's timers still to fall due, sorted.
local function liveTimers()
  local queued = {}
  for _, t in ipairs(queue) do
    queued[t] = not t.cancelled
  end
  local out = {}
  for name, handle in pairs(Timer) do
    if type(name) == "string" and queued[entries[handle]] then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

-- An error in a timer or in a reply's handler is caught where it is raised.
local errors = {}
function ON_TIMER_ERROR(_, err)
  errors[#errors + 1] = tostring(err)
end
function ON_UNHANDLED_REJECTION(err)
  errors[#errors + 1] = tostring(err)
end

---------------------------------------------------------------------------
-- Stand-in transports: a request is held until the test answers it.
---------------------------------------------------------------------------

--- Every request made and not yet answered, oldest first, on any transport.
local held = {}

local Transport = {}
Transport.__index = Transport

function Transport:configure(config)
  self.config = config
end

function Transport:reset()
  self.resets = self.resets + 1
end

function Transport:connect()
  local d = deferred.new()
  self.handshakes[#self.handshakes + 1] = d
  return d
end

function Transport:request(payload)
  local request = { transport = self, payload = payload, at = now, d = deferred.new() }
  held[#held + 1] = request
  return request.d
end

-- The driver's three transports, as it made them when it was last loaded.
local klap, klapV1, legacy

package.loaded["tplink.klap"] = {
  new = function(_, opts)
    local transport = setmetatable({ handshakes = {}, resets = 0 }, Transport)
    if Select(opts, "authVersion") == 1 then
      klapV1 = transport
    else
      klap = transport
    end
    return transport
  end,
}
package.loaded["tplink.legacy"] = {
  new = function()
    legacy = setmetatable({ handshakes = {}, resets = 0 }, Transport)
    return legacy
  end,
}

-- The TPAP transport, and each discover asked, held until the test answers it.
local tpap
local discovers = {}
package.loaded["tplink.tpap"] = {
  new = function()
    tpap = setmetatable({ handshakes = {}, resets = 0 }, Transport)
    return tpap
  end,
  discover = function()
    local d = deferred.new()
    discovers[#discovers + 1] = d
    return d
  end,
  supports = function(info)
    return info.tls == 0 and info.pake[1] == 2
  end,
}

local BULB_SERVICE = "smartlife.iot.smartbulb.lightingservice"

--- What a held request asks: "poll", "fades" for a read of the light's own
--- fades, or the params of the command or the setting it carries.
local function asks(request)
  local payload = request.payload
  if payload.method == "get_device_info" or Select(payload, "system", "get_sysinfo") then
    return "poll"
  end
  if payload.method == "get_on_off_gradually_info" then
    return "fades"
  end
  return payload.params or Select(payload, BULB_SERVICE, "transition_light_state")
end

--- What is in flight: each held request, as asks() gives it.
local function flying()
  local out = {}
  for i, request in ipairs(held) do
    out[i] = asks(request)
  end
  return out
end

--- What a color strip answers get_device_info with: on at full, in red.
local function info(fields)
  local out = {
    device_on = true,
    brightness = 100,
    hue = 0,
    saturation = 100,
    color_temp = 0,
    color_temp_range = { 2500, 6500 },
  }
  for k, v in pairs(fields or {}) do
    out[k] = v
  end
  return out
end

--- What a Kasa color bulb answers get_sysinfo with: on at full, in red.
local function sysinfo(lightState)
  local state = { on_off = 1, brightness = 100, hue = 0, saturation = 100, color_temp = 0 }
  for k, v in pairs(lightState or {}) do
    state[k] = v
  end
  return {
    system = {
      get_sysinfo = {
        err_code = 0,
        model = "KL130(US)",
        is_dimmable = 1,
        is_color = 1,
        is_variable_color_temp = 1,
        light_state = state,
      },
    },
  }
end

--- Answer a held request, the oldest unless `i` names another: a SMART result,
--- or an IOT response whole. With none there, as on a driver that sent nothing,
--- it does nothing, and the check after it says so.
local function reply(result, i)
  local request = table.remove(held, i or 1)
  if request == nil then
    return
  end
  if request.payload.method then
    request.d:resolve({ error_code = 0, result = result or {} })
  else
    request.d:resolve(result or { [BULB_SERVICE] = { transition_light_state = { err_code = 0 } } })
  end
end

local TIMED_OUT = "Legacy: request timed out (no response on UDP 9999)"

--- Fail the oldest held request, as a transport does one it got no answer to.
local function fail(reason)
  local request = table.remove(held, 1)
  if request ~= nil then
    request.d:reject({ error = reason or TIMED_OUT })
  end
end

---------------------------------------------------------------------------
-- The light, and what it tells the proxy
---------------------------------------------------------------------------

-- xy as hue and saturation over their ranges, and a color temperature as x:
-- the shim converts no colors.
function C4:ColorXYtoHSV(x, y)
  return x * 360, y * 100
end

function C4:ColorHSVtoXY(h, s)
  return h / 360, s / 100
end

function C4:ColorCCTtoXY(kelvin)
  return kelvin / 10000, 0.4
end

function C4:ColorXYtoCCT(x)
  return x * 10000
end

local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return config(self, section)
end

-- The light's proxy and its answer to GET_SETUP: an empty one unless a case
-- gives one, false for none, or a function that gives it.
local proxySetup = ""
function C4:GetProxyDevices()
  return 727
end
-- The project's button LED colors, as dev's project has them.
local project = {
  TopLEDOn = "0000ff",
  TopLEDOff = "000000",
  BottomLEDOn = "000000",
  BottomLEDOff = "0000ff",
  ToggleLEDOn = "0000ff",
  ToggleLEDOff = "000000",
}
function C4:GetProjectProperty(name)
  return project[name]
end
-- What the proxy shows, or nil for one never told it: its Brightness Percent (1001) and Current Color Chromaticity
-- (1200, to six figures as a dev proxy shows it), each the current a CHANGED or CHANGING told it, and their targets
-- (1110, 1210), a CHANGING's target or a CHANGED's value.
local shows = {}
function C4:GetDeviceVariable(id, variable)
  if id == 727 then
    return shows[variable]
  end
end
-- Its Navigator Dynamic Capabilities (6661) as dev's proxies list them: the proxy holds driver.xml's capabilities and
-- what it was told since, or driver.xml's alone after a controller start. It takes a notify's capabilities in a fixed
-- order and writes all it holds to 6661 at each that changes one of the keys that rewrite it, so one taken after the
-- last such change lags in 6661 (2026-11-03). Those it holds apart from 6661 are `shows.lags`. Without dimming it lists
-- its rate ranges 0 and has no 1110 (2026-10-24).
local CAPABILITY_KEYS = {
  "dimmer",
  "supports_target",
  "supports_brightness_stop",
  "supports_color",
  "supports_color_correlated_temperature",
  "supports_color_stop",
  "brightness_rate_min",
  "brightness_rate_max",
  "color_correlated_temperature_min",
  "color_correlated_temperature_max",
  "color_rate_behavior",
  "color_rate_min",
  "color_rate_max",
  "has_extras",
  "click_rate_min",
  "click_rate_max",
  "hold_rate_min",
  "hold_rate_max",
  "cold_start",
  "supports_color_cycling",
  "advanced_scene_support",
  "hide_proxy_properties",
  "hide_proxy_commands",
  "hide_proxy_events",
  "hide_proxy_conditionals_loops",
}
--- The order the proxy takes a notify's capabilities in, each with whether a change to it rewrites 6661. Measured on
--- dev (2026-11-03): supports_target, dimmer, supports_color, supports_color_correlated_temperature, has_extras and
--- cold_start come before the stop flags, the brightness rates after supports_target, and the color rates and CCT range
--- after the stop flags. The rest of the order is inferred.
local TAKEN = {
  { "dimmer", true },
  { "supports_target", true },
  { "supports_color", true },
  { "supports_color_correlated_temperature", true },
  { "brightness_rate_min", false },
  { "brightness_rate_max", false },
  { "has_extras", true },
  { "cold_start", true },
  { "supports_brightness_stop", false },
  { "supports_color_stop", false },
  { "color_rate_behavior", true },
  { "color_rate_min", true },
  { "color_rate_max", true },
  { "color_correlated_temperature_min", true },
  { "color_correlated_temperature_max", true },
}
--- What 6661 lists of the modeled proxy's capabilities.
local function listed(key)
  return (shows[6661] or ""):match("<" .. key .. ">([^<]*)</" .. key .. ">")
end
--- Put the modeled proxy on driver.xml's capabilities where it shows none, then take those it is `told`.
local function showCapabilities(told)
  local caps, lags = {}, shows[6661] and shows.lags or {}
  -- driver.xml's capabilities, as the build writes them from the light's profile.
  local static = ""
  for _, cap in ipairs(Caps.static(Light.made[#Light.made].profile)) do
    static = static .. ("<%s>%s</%s>"):format(cap.key, cap.value, cap.key)
  end
  for _, key in ipairs(CAPABILITY_KEYS) do
    caps[key] = lags[key] or listed(key) or static:match("<" .. key .. ">([^<]*)</" .. key .. ">") or "False"
  end
  local function rewrite()
    local xml = {}
    for _, key in ipairs(CAPABILITY_KEYS) do
      local value = caps[key]
      if caps.dimmer ~= "True" and key:match("^%l+_rate_m%l%l$") and not key:match("^color") then
        value = "0"
      end
      xml[#xml + 1] = ("<%s>%s</%s>"):format(key, value, key)
    end
    shows[6661] = "<DynamicCapabilities>" .. table.concat(xml) .. "</DynamicCapabilities>"
  end
  if not shows[6661] then
    rewrite()
  end
  for _, taken in ipairs(TAKEN) do
    local key, value = taken[1], (told or {})[taken[1]]
    if value ~= nil then
      value = type(value) == "boolean" and (value and "True" or "False") or tostring(value)
      if value ~= caps[key] then
        caps[key] = value
        if taken[2] then
          rewrite()
        end
      end
    end
  end
  shows.lags = {}
  for _, key in ipairs(CAPABILITY_KEYS) do
    if caps[key] ~= listed(key) then
      shows.lags[key] = caps[key]
    end
  end
  if caps.dimmer ~= "True" then
    shows[1110] = nil
  end
end
--- Keep what a notify tells the proxy in `shows`. One without dimming asks for the level at ONLINE_CHANGED true, before
--- the notify returns (637 and 638 on dev, 2026-10-24).
local function heard(command, p)
  local function xy(x, y, mode)
    return ("%g,%g,%d"):format(x, y, mode)
  end
  local dims = not (shows[6661] or ""):find("<dimmer>False</dimmer>", 1, true)
  if command == "LIGHT_BRIGHTNESS_CHANGED" or command == "LIGHT_BRIGHTNESS_CHANGING" then
    shows[1001] = tostring(p.LIGHT_BRIGHTNESS_CURRENT)
    shows[1110] = dims and tostring(p.LIGHT_BRIGHTNESS_TARGET or p.LIGHT_BRIGHTNESS_CURRENT) or nil
  elseif command == "ONLINE_CHANGED" and p.STATE and not dims then
    ReceivedFromProxy(PROXY, "GET_LIGHT_LEVEL", {})
  elseif
    command == "LIGHT_COLOR_CHANGED"
    and p.LIGHT_COLOR_CURRENT_PRESET_ID
    and not p.LIGHT_COLOR_CURRENT_PRESET_ORIGIN
  then
    return -- the proxy drops one that names a preset id without its origin (dev, 2026-10-29)
  elseif command == "LIGHT_COLOR_CHANGED" or command == "LIGHT_COLOR_CHANGING" then
    shows[1200] = xy(p.LIGHT_COLOR_CURRENT_X, p.LIGHT_COLOR_CURRENT_Y, p.LIGHT_COLOR_CURRENT_COLOR_MODE)
    shows[1210] = p.LIGHT_COLOR_TARGET_X
        and xy(p.LIGHT_COLOR_TARGET_X, p.LIGHT_COLOR_TARGET_Y, p.LIGHT_COLOR_TARGET_COLOR_MODE)
      or shows[1200]
  elseif command == "DYNAMIC_CAPABILITIES_CHANGED" then
    showCapabilities(p)
  end
end
local uiRequest = C4.SendUIRequest
function C4:SendUIRequest(id, request, params)
  if request == "GET_SETUP" then
    if type(proxySetup) == "function" then
      return proxySetup()
    end
    return proxySetup or nil
  end
  return uiRequest(self, id, request, params)
end

local sent, statuses, start = {}, {}, now

--- Whether each property is hidden, as the driver last set it.
local hidden = {}
function C4:SetPropertyAttribs(name, attrib)
  hidden[name] = attrib == 1
end

function C4:UpdateProperty(name, value)
  Properties[name] = value
  if name == "Driver Status" then
    statuses[#statuses + 1] = value
  end
end

--- Count what the proxy is told, and each Driver Status written, from here.
local function mark()
  sent, statuses, start = {}, {}, now
end

local function status()
  return Properties["Driver Status"]
end

--- Set a property as Composer does: the value, then the driver's handler.
local function setProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

--- Load the driver afresh and start it with these properties over the usual,
--- on a proxy that shows nothing.
local function startDriver(properties)
  queue, held, shows = {}, {}, {}
  Properties = {
    ["Driver Status"] = "",
    ["IP Address"] = "192.0.2.24",
    ["Protocol"] = "Auto",
    ["TP-Link Username"] = "user@example.com",
    ["TP-Link Password"] = "not-a-password",
    ["Poll Rate (Seconds)"] = "5",
  }
  for name, value in pairs(properties or {}) do
    Properties[name] = value
  end
  dofile(DRIVER)
  function SendToProxy(idBinding, strCommand, tParams)
    sent[#sent + 1] = { at = now - start, binding = idBinding, command = strCommand, params = tParams or {} }
    if idBinding == PROXY then
      heard(strCommand, tParams or {})
    end
  end
  -- As OnDriverInit leaves it: no property's handler starts the backend.
  gInitialized = false
  ShimLateInit()
  -- The license gate's 10 s read is not one of the light's timers, which this suite times.
  require("lib.drivercentral")._timer:Cancel()
  mark()
end

--- Complete the KLAP handshake the driver asked for last.
local function shakeHands()
  klap.handshakes[#klap.handshakes]:resolve(klap)
end

--- A color strip connected over KLAP with the SMART schema, as info() has it.
local function light(fields, properties)
  startDriver(properties)
  shakeHands()
  reply(info(fields))
  mark()
end

--- A Kasa color bulb connected over the legacy port, as sysinfo() has it.
local function bulb(lightState)
  startDriver({ ["Protocol"] = "Legacy" })
  reply(sysinfo(lightState))
  mark()
end

local function proxy(command, params)
  ReceivedFromProxy(PROXY, command, params or {})
end

--- Each `field` the proxy got with `command` since the mark: "at" is the ms,
--- and with no field the params whole.
local function told(command, field)
  local out = {}
  for _, s in ipairs(sent) do
    if s.binding == PROXY and s.command == command then
      out[#out + 1] = field == "at" and s.at or field == nil and s.params or s.params[field]
    end
  end
  return out
end

local function levels()
  return told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
end

--- A color by its hue and saturation, as the xy the proxy sends.
local function xy(hue, saturation)
  return { hue / 360, saturation / 100 }
end

local BLUE = xy(240, 100)

local function colorTarget(color, rate)
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = color[1], LIGHT_COLOR_TARGET_Y = color[2], LIGHT_COLOR_TARGET_COLOR_RATE = rate }
  )
end

T.section("commands made while one is in flight wait for its answer, and go out as one with the last values")
do
  light()
  for _, level in ipairs({ 10, 20, 30, 40, 50 }) do
    proxy("SET_LEVEL", { LEVEL = level })
  end
  T.eq("five levels at once: one request reaches the light", flying(), { { device_on = true, brightness = 10 } })
  T.eq("the proxy is told each as it is asked", levels(), { 10, 20, 30, 40, 50 })
  reply()
  T.eq("after its answer one more, with the last level", flying(), { { device_on = true, brightness = 50 } })
  reply()
  T.eq("and nothing after that", flying(), {})
  proxy("SET_LEVEL", { LEVEL = 60 })
  proxy("SET_LEVEL", { LEVEL = 70 })
  fail()
  T.eq("a failure lets the next go as an answer does", flying(), { { device_on = true, brightness = 70 } })
  reply()

  -- Twenty levels 100 ms apart to a light that takes 300 ms over each.
  light()
  local most, requests, last = 0, 0, nil
  for level = 1, 20 do
    proxy("SET_LEVEL", { LEVEL = level })
    for _ = 1, 100 do
      if held[1] and now - held[1].at >= 300 then
        requests, last = requests + 1, asks(held[1]).brightness
        reply()
      end
      most = math.max(most, #held)
      run(1)
    end
  end
  while held[1] do
    requests, last = requests + 1, asks(held[1]).brightness
    reply()
  end
  T.eq("a stream of levels: never more than one request in flight", most, 1)
  T.eq("the light ends on the last", last, 20)
  T.check("and is sent the latest each time, not every one", requests < 10, requests)
end

T.section("commands that wait together are merged field by field, the later value winning")
do
  --- The request that follows the one in flight, once that is answered.
  local function merged()
    reply()
    local out = flying()[1]
    reply()
    return out
  end
  light()
  proxy("SET_LEVEL", { LEVEL = 10 })
  proxy("SET_LEVEL", { LEVEL = 40 })
  colorTarget(BLUE, 0)
  T.eq(
    "a level and then a color: one request with both",
    merged(),
    { device_on = true, brightness = 40, hue = 240, saturation = 100, color_temp = 0 }
  )
  proxy("SET_LEVEL", { LEVEL = 10 })
  colorTarget(xy(120, 50), 0)
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("a color and then a color temperature: the color is gone", merged(), { device_on = true, color_temp = 3000 })
  proxy("SET_LEVEL", { LEVEL = 20 })
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  colorTarget(BLUE, 0)
  T.eq(
    "a color temperature and then a color: the color",
    merged(),
    { device_on = true, hue = 240, saturation = 100, color_temp = 0 }
  )
  proxy("SET_LEVEL", { LEVEL = 10 })
  proxy("SET_LEVEL", { LEVEL = 60 })
  proxy("OFF")
  T.eq("a level and then an off: the off alone", merged(), { device_on = false })
  -- A fade time, on a light that takes one from a command.
  bulb()
  proxy("SET_LEVEL", { LEVEL = 10 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
  proxy("SET_LEVEL", { LEVEL = 30 })
  T.eq("a rate and then none: no transition", merged(), { on_off = 1, brightness = 30, ignore_default = 1 })
  proxy("SET_LEVEL", { LEVEL = 10 })
  proxy("SET_LEVEL", { LEVEL = 30 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
  T.eq(
    "none and then a rate: the rate",
    merged(),
    { on_off = 1, brightness = 80, ignore_default = 1, transition_period = 3000 }
  )
end

T.section("a poll takes its turn with the commands, and one sent before a command is not news of the light")
do
  light()
  proxy("SET_LEVEL", { LEVEL = 30 })
  run(5000)
  T.eq("a poll due while a command is in flight waits", flying(), { { device_on = true, brightness = 30 } })
  run(5000)
  reply()
  T.eq("and goes out once, after the command's answer", flying(), { "poll" })
  mark()
  reply(info({ brightness = 30 }))
  T.eq("where it reads what the command set", levels(), {})

  run(5000)
  T.eq("a poll is in flight", flying(), { "poll" })
  mark()
  proxy("SET_LEVEL", { LEVEL = 60 })
  proxy("SET_LEVEL", { LEVEL = 70 })
  T.eq("a command made then waits for it", flying(), { "poll" })
  reply(info({ brightness = 30 }))
  T.eq("its answer, the light before the command, tells the proxy nothing", levels(), { 60, 70 })
  T.eq("and the command goes out next", flying(), { { device_on = true, brightness = 70 } })
  reply()
  run(5000)
  mark()
  reply(info({ brightness = 55 }))
  T.eq("the poll after it is news again", levels(), { 55 })

  proxy("SET_LEVEL", { LEVEL = 30 })
  run(5000)
  proxy("SET_LEVEL", { LEVEL = 40 })
  reply()
  reply()
  reply(info({ brightness = 40 }))
end

T.section("a request the light never answers is given up on, and what waited for it goes")
do
  light()
  proxy("SET_LEVEL", { LEVEL = 30 })
  proxy("SET_LEVEL", { LEVEL = 40 })
  mark()
  run(14000)
  T.eq("for 14 s the request in flight is waited for", flying(), { { device_on = true, brightness = 30 } })
  T.eq("and the proxy is told nothing", sent, {})
  run(2000)
  T.eq("past 15 s the command that waited goes out", flying()[2], { device_on = true, brightness = 40 })
  T.eq("and the light is told as not answering", told("ONLINE_CHANGED", "STATE"), { false })
  reply(nil, 1)
  proxy("OFF")
  T.eq(
    "the answer it was given up on, if it comes, lets nothing past the one in flight",
    flying(),
    { { device_on = true, brightness = 40 } }
  )
  reply()
  T.eq("an Off made while the light was not answering is dropped: the poll goes next", flying(), { "poll" })
  mark()
  reply(info({ device_on = false }))
  T.eq("whose answer is the light connected again", told("ONLINE_CHANGED", "STATE"), { true })

  bulb()
  run(5000)
  proxy("SET_LEVEL", { LEVEL = 30 })
  run(16000)
  T.eq("a Kasa bulb's poll: the same", flying()[2], { on_off = 1, brightness = 30, ignore_default = 1 })

  -- A request its transport fails at once, as one with no session to go on.
  light()
  proxy("SET_LEVEL", { LEVEL = 30 })
  run(5000)
  proxy("SET_LEVEL", { LEVEL = 40 })
  local request = klap.request
  function klap:request()
    self.request = request
    return deferred.new():reject({ error = "Klap: no session established" })
  end
  reply()
  T.eq("a request failed as it is made lets the poll behind it go", flying(), { "poll" })
  proxy("ON")
  run(16000)
  T.eq("and that poll is given up on in its turn, the On made meanwhile dropped", flying()[2], "poll")
end

T.section("a Kasa bulb on the IOT schema is sent one request at a time too")
do
  bulb()
  for _, level in ipairs({ 10, 20, 30, 40, 50 }) do
    proxy("SET_LEVEL", { LEVEL = level })
  end
  T.eq(
    "five levels at once: one request reaches the bulb",
    flying(),
    { { on_off = 1, brightness = 10, ignore_default = 1 } }
  )
  reply()
  T.eq(
    "after its answer one more, with the last level",
    flying(),
    { { on_off = 1, brightness = 50, ignore_default = 1 } }
  )
  run(5000)
  T.eq("a poll due meanwhile waits", #flying(), 1)
  reply()
  T.eq("and goes out after the answer", flying(), { "poll" })
  mark()
  proxy("SET_LEVEL", { LEVEL = 60 })
  T.eq("a command made while it is in flight waits for it", flying(), { "poll" })
  reply(sysinfo({ brightness = 50 }))
  T.eq("a poll sent before a command tells the proxy nothing", levels(), { 60 })
  T.eq("and the command goes out next", flying(), { { on_off = 1, brightness = 60, ignore_default = 1 } })
  reply()
end

T.section("a connect attempt that a later one has replaced does nothing more")
do
  -- Protocol set to Legacy and, before that probe has timed out, back to Auto.
  light()
  local resets = legacy.resets
  setProperty("Protocol", "Legacy")
  T.eq("Legacy: the legacy port is probed", #held == 1 and held[1].transport, legacy)
  T.eq("on a transport reset first, so no probe waits behind the last attempt's", legacy.resets, resets + 1)
  setProperty("Protocol", "Auto")
  shakeHands()
  reply(info(), 2)
  T.eq("Auto again: the light connects over KLAP", status(), "Connected (SMART)")
  mark()
  fail()
  T.eq("the Legacy attempt's probe then times out: the status stands", status(), "Connected (SMART)")
  T.eq("and the proxy is told nothing", sent, {})

  -- Protocol set to KLAP and, before its handshake is done, to Legacy.
  light()
  setProperty("Protocol", "KLAP")
  local handshake = klap.handshakes[#klap.handshakes]
  setProperty("Protocol", "Legacy")
  mark()
  handshake:resolve(klap)
  T.eq(
    "the KLAP attempt's handshake then completes: nothing is asked over it",
    #held == 1 and held[1].transport,
    legacy
  )
  T.eq("the light is not taken as connected", told("ONLINE_CHANGED", "STATE"), {})
  T.eq("and the status is the Legacy attempt's", status(), "Connecting (Legacy)...")
  fail()
  T.eq("as it is when that attempt ends", status(), "Disconnected: " .. TIMED_OUT)

  -- Each later step of a KLAP attempt, ended after Protocol became Legacy.
  --- The status, what the proxy was told and whether the Legacy attempt's
  --- probe alone is in flight, once `land` has ended the step `reach` brought
  --- a KLAP attempt to.
  local function afterReplaced(reach, land)
    light()
    setProperty("Protocol", "KLAP")
    reach()
    setProperty("Protocol", "Legacy")
    mark()
    land()
    return { status(), told("ONLINE_CHANGED", "STATE"), #held == 1 and held[1].transport == legacy }
  end
  local NOTHING = { "Connecting (Legacy)...", {}, true }
  local function toIotProbe()
    shakeHands()
    fail("not a SMART device")
  end
  local function toV1Handshake()
    klap.handshakes[#klap.handshakes]:reject({ error = "Klap: handshake1 auth mismatch" })
  end
  T.eq(
    "its SMART probe is answered: nothing is adopted",
    afterReplaced(shakeHands, function()
      reply(info(), 1)
    end),
    NOTHING
  )
  T.eq(
    "its SMART probe fails: no IOT probe follows over KLAP",
    afterReplaced(shakeHands, function()
      fail("not a SMART device")
    end),
    NOTHING
  )
  T.eq(
    "its IOT probe over KLAP is answered: nothing is adopted",
    afterReplaced(toIotProbe, function()
      reply(sysinfo(), 1)
    end),
    NOTHING
  )
  T.eq(
    "its handshake fails: the status is not its reason",
    afterReplaced(function() end, function()
      klap.handshakes[#klap.handshakes]:reject({ error = "Klap: refused" })
    end),
    NOTHING
  )
  T.eq(
    "its handshake with v1 hashing completes: no probe follows over it",
    afterReplaced(toV1Handshake, function()
      klapV1.handshakes[#klapV1.handshakes]:resolve(klapV1)
    end),
    NOTHING
  )
  T.eq(
    "its handshake with v1 hashing fails: the status is not its reason",
    afterReplaced(toV1Handshake, function()
      klapV1.handshakes[#klapV1.handshakes]:reject({ error = "Klap: refused" })
    end),
    NOTHING
  )
end

T.section("an answer to a poll or a command sent before the backend was started again is not acted on")
do
  light()
  run(5000)
  T.eq("a poll is in flight", flying(), { "poll" })
  setProperty("Poll Rate (Seconds)", "10")
  mark()
  reply(info({ brightness = 30 }))
  T.eq("its answer after the restart tells the proxy nothing", sent, {})
  T.eq("and is not the new attempt's connection", status(), "Connecting (KLAP)...")
  shakeHands()
  reply(info())
  T.eq("which its own probe makes", status(), "Connected (SMART)")

  light()
  proxy("SET_LEVEL", { LEVEL = 30 })
  setProperty("Poll Rate (Seconds)", "10")
  shakeHands()
  reply(info(), 2)
  proxy("SET_LEVEL", { LEVEL = 40 })
  reply(nil, 1)
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "a command's answer after the restart does not let the next past the one in flight",
    flying(),
    { { device_on = true, brightness = 40 } }
  )
  reply()
  T.eq("which goes when that one is answered", flying(), { { device_on = true, brightness = 50 } })
  reply()

  light()
  proxy("SET_LEVEL", { LEVEL = 30 })
  run(5000)
  proxy("SET_LEVEL", { LEVEL = 40 })
  setProperty("Poll Rate (Seconds)", "10")
  shakeHands()
  reply(info(), 2)
  proxy("SET_LEVEL", { LEVEL = 60 })
  reply(nil, 2)
  T.eq(
    "a command and a poll that waited before the restart are not sent after it",
    flying(),
    { { device_on = true, brightness = 30 } }
  )
end

T.section("while no light is found the poll timer tries again, and says nothing until the outcome changes")
do
  startDriver({ ["Protocol"] = "Legacy" })
  T.eq("an attempt says what it is trying", status(), "Connecting (Legacy)...")
  fail()
  T.eq("and why it found no light", status(), "Disconnected: " .. TIMED_OUT)
  mark()
  run(5000)
  T.eq("the retry probes again", flying(), { "poll" })
  T.eq("without a word", statuses, {})
  fail()
  T.eq("nor when it fails the same way", statuses, {})
  T.eq("so the reason stands", status(), "Disconnected: " .. TIMED_OUT)
  run(5000)
  reply(sysinfo())
  T.eq("a retry that finds the light says so", status(), "Connected (Legacy)")

  startDriver()
  run(12000)
  T.eq("an attempt still waiting on its handshake is not replaced by a retry", #klap.handshakes, 1)
  shakeHands()
  reply(info())
  T.eq("and connects when the light answers", status(), "Connected (SMART)")
end

--- A scene element setting a level over `rate` ms.
local function levelStep(level, rate)
  local step = "<element><delay>0</delay><rate>%d</rate><brightnessEnabled>true</brightnessEnabled>"
    .. "<brightness>%d</brightness></element>"
  return step:format(rate, level)
end

T.section("a Kasa bulb's rated on from off is one request: no bare on goes ahead of it")
do
  local off = { on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } }
  bulb(off)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq(
    "a level over a rate: the on, the level and the rate together",
    flying(),
    { { on_off = 1, brightness = 50, ignore_default = 1, transition_period = 2000 } }
  )
  reply()
  T.eq("with nothing behind it", flying(), {})
  bulb(off)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(30, 3000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a scene step over a rate: the same",
    flying(),
    { { on_off = 1, brightness = 30, ignore_default = 1, transition_period = 3000 } }
  )
  reply()
  T.eq("with nothing behind it", flying(), {})
  proxy("CLEAR_ALL_SCENES")
end

---------------------------------------------------------------------------
-- A Tapo strip whose fades the driver makes
---------------------------------------------------------------------------

--- What the stand-in strip holds: what it was connected with, and every
--- command it has answered since.
local strip = {}

--- The strip's own fades, as it answers a read of them: all on, a second each
--- way, as a Tapo strip comes.
local own = {}

--- The most requests the strip has had in flight together since it connected.
local busiest = 0

--- A strip connected as light() connects one, whose answers serve() gives.
local function walked(fields, properties)
  strip, busiest = info(fields), 0
  own = {
    on_state = { enable = true, duration = 1, max_duration = 60 },
    off_state = { enable = true, duration = 1, max_duration = 60 },
    change_state = { enable = true },
  }
  light(fields, properties)
end

local NO_POLLS = { ["Poll Rate (Seconds)"] = "300" }

--- Let time pass to the next timer that falls due, or to `at` where that is
--- sooner, and no further than `stop`.
local function advance(stop, at)
  local to = math.min(stop, at or stop)
  for _, t in ipairs(queue) do
    if not t.cancelled and t.at > now and t.at < to then
      to = t.at
    end
  end
  run(to - now)
end

--- Let `ms` pass on a strip that answers each request `takes` ms after it is
--- made. Returns each command and setting answered, and how many polls were.
local function serve(ms, takes)
  local commands, polls, stop = {}, 0, now + ms
  while now < stop do
    local request = held[1]
    busiest = math.max(busiest, #held)
    if request == nil or now - request.at < takes then
      advance(stop, request and request.at + takes)
    elseif asks(request) == "poll" then
      polls = polls + 1
      reply(info(strip))
    elseif asks(request) == "fades" then
      local answer = {}
      for name, state in pairs(own) do
        answer[name] = type(state) == "table"
            and { enable = state.enable, duration = state.duration, max_duration = state.max_duration }
          or state
      end
      reply(answer)
    else
      local holds = request.payload.method == "set_on_off_gradually_info" and own or strip
      for field, value in pairs(asks(request)) do
        holds[field] = type(value) == "table" and { enable = value.enable, duration = value.duration } or value
      end
      commands[#commands + 1] = { at = request.at - start, sent = asks(request) }
      reply()
    end
  end
  return commands, polls
end

--- Each `field` of the commands serve() returned that name it, or "at", the
--- ms each was sent at.
local function each(commands, field)
  local out = {}
  for _, command in ipairs(commands) do
    out[#out + 1] = field == "at" and command.at or command.sent[field]
  end
  return out
end

--- A scene element fading to a level and a color over `rate` ms.
local function colorStep(level, color, rate)
  local step = "<element><delay>0</delay><rate>%d</rate><brightnessEnabled>true</brightnessEnabled>"
    .. "<brightness>%d</brightness><colorEnabled>true</colorEnabled><colorX>%s</colorX><colorY>%s</colorY>"
    .. "<colorMode>0</colorMode></element>"
  return step:format(rate, level, color[1], color[2])
end

T.section("once a fade has ended, by any way, no timer is left but the poll's and the update check's")
do
  local fadeUp = { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 }
  for _, c in ipairs({
    {
      "a level fade run to its end",
      function()
        proxy("SET_BRIGHTNESS_TARGET", fadeUp)
      end,
    },
    {
      "a level fade stopped half way",
      function()
        proxy("SET_BRIGHTNESS_TARGET", fadeUp)
        serve(2000, 250)
        proxy("SET_BRIGHTNESS_STOP")
      end,
    },
    {
      "a color fade run to its end",
      function()
        colorTarget(BLUE, 4000)
      end,
    },
    {
      "a color fade stopped half way",
      function()
        colorTarget(BLUE, 4000)
        serve(2000, 250)
        proxy("SET_COLOR_STOP")
      end,
    },
    {
      "a fade to off",
      function()
        proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
      end,
    },
    {
      "a scene's fades",
      function()
        proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(80, BLUE, 2000) .. levelStep(10, 2000) })
        proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
      end,
    },
    {
      "a fade a level command replaces",
      function()
        proxy("SET_BRIGHTNESS_TARGET", fadeUp)
        serve(2000, 250)
        proxy("SET_LEVEL", { LEVEL = 40 })
      end,
    },
    {
      "a fade another hand ends",
      function()
        -- Slow enough that the next poll comes before the next step.
        proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300000 })
        serve(9000, 250)
        strip.brightness = 70
      end,
      {},
    },
    {
      "a fade whose step the strip never answers",
      function()
        proxy("SET_BRIGHTNESS_TARGET", fadeUp)
        serve(2000, 250)
        fail("Klap: request timed out")
      end,
    },
    {
      "a fade a Reconnect ends",
      function()
        proxy("SET_BRIGHTNESS_TARGET", fadeUp)
        serve(2000, 250)
        EC.Reconnect()
        shakeHands()
      end,
    },
    {
      "a fade that Fades set to Light ends",
      function()
        proxy("SET_BRIGHTNESS_TARGET", fadeUp)
        serve(2000, 250)
        setProperty("Fades", "Light")
      end,
    },
  }) do
    walked({ brightness = 5 }, c[3] or NO_POLLS)
    c[2]()
    -- Past the 15 s a request in flight at a restart is waited for.
    serve(20000, 250)
    while held[1] do
      reply(info(strip))
    end
    T.eq(c[1] .. ": the poll's timer and the update check's alone", liveTimers(), { "DirectPoll", "UpdateCheck" })
    proxy("CLEAR_ALL_SCENES")
  end
end

---------------------------------------------------------------------------
-- The Fades property
---------------------------------------------------------------------------

--- The capabilities that say whose a fade's length is, as the proxy was last
--- told them since the mark.
local function rates()
  local out = {}
  for _, capabilities in ipairs(told("DYNAMIC_CAPABILITIES_CHANGED")) do
    for _, name in ipairs({
      "has_fixed_ramp_rate",
      "fixed_ramp_rate",
      "brightness_rate_min",
      "brightness_rate_max",
      "color_rate_behavior",
      "color_rate_min",
      "color_rate_max",
      "supports_brightness_stop",
      "supports_color_stop",
    }) do
      if capabilities[name] ~= nil then
        out[name] = capabilities[name]
      end
    end
  end
  return out
end

--- The capabilities for a light that fades by itself, `ms` between two states.
local function lights(ms)
  return {
    has_fixed_ramp_rate = true,
    fixed_ramp_rate = ms,
    brightness_rate_min = ms,
    brightness_rate_max = ms,
    color_rate_behavior = 0,
    color_rate_min = 0,
    color_rate_max = 65535,
    supports_brightness_stop = false,
    supports_color_stop = false,
  }
end

T.section("Fades is shown for a strip on the SMART schema, and hidden for a Kasa bulb and a light on an outlet")
do
  startDriver()
  T.eq("while no light is connected it is hidden", hidden["Fades"], true)
  shakeHands()
  reply(info())
  T.eq("a strip on the SMART schema: shown", hidden["Fades"], false)
  startDriver({ ["Protocol"] = "Legacy" })
  reply(sysinfo())
  T.eq("a Kasa bulb on the IOT schema: hidden", hidden["Fades"], true)
  setProperty("Fades", "Light")
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  T.eq(
    "and Light means nothing to it: the bulb is sent the rate, and nothing else",
    flying(),
    { { on_off = 1, brightness = 30, ignore_default = 1, transition_period = 2000 } }
  )
  light()
  setProperty("Fades", "Driver")
  T.eq("on a strip, the mode it is already in is no change: nothing is sent or told", { flying(), sent }, { {}, {} })
  C4:Bind(900, 1, C4:GetDeviceID(), 1, "TPLINK_LIGHT")
  startDriver({ ["Fades"] = "Light" })
  RFP.UPDATE_STATE(1, "UPDATE_STATE", {
    entity = SerializeSafe({ supported_color_modes = { require("constants").LightColorMode.COLOR_MODE_ON_OFF } }),
    state = SerializeSafe({ state = true }),
  })
  T.eq("a light bound to an outlet: hidden", hidden["Fades"], true)
  T.eq("with no fixed rate, whatever the property was left at", rates().has_fixed_ramp_rate, false)
  C4:Unbind(C4:GetDeviceID(), 1)
end

T.section("Fades set to Light: the strip's own fades are read, and those that are off switched on at their own lengths")
do
  walked({}, NO_POLLS)
  -- On in 3 s but switched off, off in 2 s, and no fade between two states.
  own.on_state = { enable = false, duration = 3, max_duration = 60 }
  own.off_state = { enable = true, duration = 2, max_duration = 60 }
  own.change_state = { enable = false }
  mark()
  setProperty("Fades", "Light")
  T.eq("choosing Light: the strip's own fades are read", flying(), { "fades" })
  T.eq("and the proxy is told nothing of rates until they are", rates(), {})
  local settings = serve(2000, 250)
  T.eq("the two that are off are switched on, the on fade at the 3 s it has", each(settings, "on_state"), {
    { enable = true, duration = 3 },
  })
  T.eq("and the fade between states, which has no length", each(settings, "change_state"), { { enable = true } })
  T.eq("a request each, and none for the one that was on", #settings, 2)
  T.eq("one at a time", busiest, 1)
  T.eq("so the strip keeps each length its owner set", { own.on_state.duration, own.off_state.duration }, { 3, 2 })
  T.eq("the proxy is told a fixed rate, the strip's second between two states, and no stop", rates(), lights(1000))

  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 5000 })
  T.eq("a level over 5 s: one command, with no fade time", flying(), { { device_on = true, brightness = 40 } })
  T.eq("the proxy is told the strip's own second, not the rate asked", told("LIGHT_BRIGHTNESS_CHANGING"), {
    { LIGHT_BRIGHTNESS_CURRENT = 100, LIGHT_BRIGHTNESS_TARGET = 40, RATE = 1000 },
  })
  T.eq("and nothing follows that command", #serve(6000, 250), 1)
  T.eq("the level is told when the strip has faded there", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 1000 })

  mark()
  proxy("OFF")
  T.eq("an off, which carries no rate: one command", flying(), { { device_on = false } })
  T.eq("told over the strip's 2 s off", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 2000 })
  serve(3000, 250)
  T.eq("and as off at their end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })

  mark()
  proxy("SET_LEVEL", { LEVEL = 80 })
  T.eq("a level from off: one command", flying(), { { device_on = true, brightness = 80 } })
  T.eq("told over the strip's 3 s on", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 3000 })
  serve(4000, 250)
  T.eq("and at its end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 3000 })

  mark()
  colorTarget(BLUE, 5000)
  T.eq("a color over 5 s: one command", flying(), { { device_on = true, hue = 240, saturation = 100, color_temp = 0 } })
  T.eq("told over the strip's second", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"), { 1000 })
  T.eq("with nothing after it", #serve(6000, 250), 1)
  T.eq("and at its end", told("LIGHT_COLOR_CHANGED", "at"), { 1000 })

  proxy("OFF")
  serve(3000, 250)
  mark()
  colorTarget(xy(120, 50), 5000)
  T.eq("a color for the strip while it is off is kept, and told at once", {
    flying(),
    told("LIGHT_COLOR_CHANGED", "at"),
  }, { {}, { 0 } })
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(50, 4000) })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("a scene step that fades the strip up from off is told over its 3 s on", {
    #flying(),
    told("LIGHT_BRIGHTNESS_CHANGING", "RATE"),
  }, { 1, { 3000 } })
  serve(5000, 250)
  colorTarget(BLUE, 0)
  serve(2000, 250)

  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(60, xy(0, 100), 4000) .. levelStep(30, 0) })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("a scene step that fades for 4 s: one command", flying(), {
    { device_on = true, brightness = 60, hue = 0, saturation = 100, color_temp = 0 },
  })
  T.eq("told over the strip's second", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 1000 })
  T.eq("its color too", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"), { 1000 })
  local steps = serve(6000, 250)
  T.eq("the scene's next step comes after the step's own 4 s", each(steps, "at"), { 0, 4000 })
  T.eq("the step's level and color are told at the end of the strip's second", {
    told("LIGHT_BRIGHTNESS_CHANGED", "at")[1],
    told("LIGHT_COLOR_CHANGED", "at"),
  }, { 1000, { 1000 } })
  T.eq("and the next step, which has no ramp time, over the strip's second too", {
    told("LIGHT_BRIGHTNESS_CHANGING", "RATE"),
    told("LIGHT_BRIGHTNESS_CHANGED", "at")[2],
  }, { { 1000, 1000 }, 5000 })
  proxy("CLEAR_ALL_SCENES")

  -- A color that replaces a step's starts from where the strip's second has got to.
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(60, BLUE, 4000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  serve(500, 250)
  mark()
  colorTarget(xy(120, 50), 0)
  local from = told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X")[1]
  T.eq(
    "a color 0.5 s into a step's is told from half way through the strip's second, not an eighth of the step's 4 s",
    from and math.floor(from * 360 + 0.5),
    120
  )
  serve(6000, 250)
  proxy("CLEAR_ALL_SCENES")

  -- A step that sets a color alone, with a ramp time and with none.
  local COLOR_ONLY = "<element><delay>0</delay><rate>%d</rate><brightnessEnabled>false</brightnessEnabled>"
    .. "<colorEnabled>true</colorEnabled><colorX>%s</colorX><colorY>%s</colorY><colorMode>0</colorMode></element>"
  for _, rate in ipairs({ 4000, 0 }) do
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = COLOR_ONLY:format(rate, rate == 0 and BLUE[1] or 0.5, 1) })
    mark()
    proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
    T.eq("a scene step that sets a color alone, ramp time " .. rate .. ": one command", #flying(), 1)
    serve(6000, 250)
    T.eq("told over the strip's second, and at its end", {
      told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"),
      told("LIGHT_COLOR_CHANGED", "at"),
    }, { { 1000 }, { 1000 } })
    proxy("CLEAR_ALL_SCENES")
  end

  -- The strip is off from the off on, whatever its own fade is at.
  walked({ brightness = 13 }, NO_POLLS)
  own.off_state.duration = 30
  setProperty("Fades", "Light")
  serve(1000, 250)
  proxy("OFF")
  serve(2000, 250)
  colorTarget(BLUE, 0)
  T.eq("a color 2 s into the strip's 30 s off turns no strip back on: it is kept", flying(), {})
  serve(30000, 250)
  T.eq("so the strip is off at the fade's end, as the proxy is told", { strip.device_on, levels() }, { false, { 0 } })
  proxy("ON")

  -- What the strip held before a command is no part of the fade it begins.
  walked({ brightness = 80 }, { ["Fades"] = "Light" })
  serve(6000, 250)
  strip.hue = 120
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(50, 4000) .. levelStep(30, 0) })
  run(3500)
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  steps = serve(6000, 250)
  T.eq(
    "a color another hand set before a scene, read by a poll in its first step's fade, is told",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 120 / 360 }
  )
  T.eq("and is no end to the step, nor to the scene: its next step runs", each(steps, "brightness"), { 50, 30 })
  proxy("CLEAR_ALL_SCENES")

  -- A command made while the fades are read and switched on.
  walked({}, NO_POLLS)
  own.change_state = { enable = false }
  setProperty("Fades", "Light")
  proxy("SET_LEVEL", { LEVEL = 40 })
  T.eq("a command made while the fades are read waits", flying(), { "fades" })
  steps = serve(2000, 250)
  T.eq("for the fade that is off to be switched on too", { Select(steps, 1, "sent"), Select(steps, 2, "sent") }, {
    { change_state = { enable = true } },
    { device_on = true, brightness = 40 },
  })
  T.eq("each as the one before is answered", { each(steps, "at"), busiest }, { { 250, 500 }, 1 })

  -- Light chosen while one command is in flight and another waits.
  walked({}, NO_POLLS)
  proxy("SET_LEVEL", { LEVEL = 30 })
  proxy("SET_LEVEL", { LEVEL = 40 })
  setProperty("Fades", "Light")
  T.eq("Light chosen while a command waits: the read goes ahead of it, alone", {
    #flying(),
    each(serve(300, 250), "brightness"),
    flying(),
  }, { 1, { 30 }, { "fades" } })
  T.eq("and the command behind the read", { each(serve(1000, 250), "brightness"), busiest }, { { 40 }, 1 })

  -- Driver chosen again before the strip has answered the read.
  walked({}, NO_POLLS)
  own.on_state = { enable = false, duration = 3, max_duration = 60 }
  setProperty("Fades", "Light")
  setProperty("Fades", "Driver")
  T.eq("Driver chosen before the read is answered: nothing is switched on", #serve(2000, 250), 0)

  -- A strip that refuses the write.
  walked({ device_on = false }, NO_POLLS)
  own.on_state = { enable = false, duration = 3, max_duration = 60 }
  setProperty("Fades", "Light")
  serve(300, 250)
  T.eq("a strip asked to switch its on fade on", Select(flying(), 1, "on_state"), { enable = true, duration = 3 })
  local write = table.remove(held, 1)
  if write then
    write.d:resolve({ error_code = -1008 })
  end
  mark()
  proxy("SET_LEVEL", { LEVEL = 40 })
  T.eq("a fade the strip would not switch on is none: an on is told at once", told("LIGHT_BRIGHTNESS_CHANGED", "at"), {
    0,
  })

  -- A write the strip never answers.
  walked({}, NO_POLLS)
  own.on_state.enable, own.off_state.enable = false, false
  setProperty("Fades", "Light")
  serve(300, 250)
  proxy("SET_LEVEL", { LEVEL = 40 })
  mark()
  fail("Klap: request timed out")
  T.eq(
    "a write the strip does not answer: no other is tried ahead of the command that waits",
    flying(),
    { { device_on = true, brightness = 40 } }
  )
  T.eq("and the proxy is told no fixed rate", rates().has_fixed_ramp_rate, false)
end

T.section("Fades set to Light on a strip with one switch for its fades, or with no fade between two states")
do
  -- An older strip answers with one switch for all its fades, and no length.
  walked({ brightness = 80 }, NO_POLLS)
  own = { enable = false }
  mark()
  setProperty("Fades", "Light")
  local settings = serve(1000, 250)
  T.eq("a strip whose fades are one switch that is off: it is switched on", each(settings, "enable"), { true })
  T.eq("with that one request", { #settings, own.enable }, { 1, true })
  local caps = rates()
  T.eq(
    "the proxy is told no stop, and no fixed rate: the strip gives its fade no length",
    { caps.supports_brightness_stop, caps.has_fixed_ramp_rate, caps.fixed_ramp_rate, caps.brightness_rate_max },
    { false, false, 0, 65535 }
  )
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 5000 })
  T.eq("a level over 5 s is one command", flying(), { { device_on = true, brightness = 40 } })
  T.eq("told at once, with no length to tell it over", {
    told("LIGHT_BRIGHTNESS_CHANGING"),
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
  }, { {}, { 0 } })
  serve(1000, 250)
  mark()
  proxy("OFF")
  T.eq("and so an off", { flying(), told("LIGHT_BRIGHTNESS_CHANGED", "at") }, { { { device_on = false } }, { 0 } })

  walked({}, NO_POLLS)
  own = { enable = true }
  mark()
  setProperty("Fades", "Light")
  T.eq("one switch that is on: nothing is written", serve(1000, 250), {})
  T.eq(
    "and the proxy told the same",
    { rates().supports_brightness_stop, rates().has_fixed_ramp_rate },
    { false, false }
  )

  -- A fade on and a fade off, each with its length, and no switch between.
  walked({ brightness = 80 }, NO_POLLS)
  own = {
    on_state = { enable = false, duration = 5, max_duration = 60 },
    off_state = { enable = true, duration = 10, max_duration = 60 },
  }
  mark()
  setProperty("Fades", "Light")
  T.eq(
    "a strip with no fade between two states: its on fade, which is off, is switched on",
    each(serve(1000, 250), "on_state"),
    { { enable = true, duration = 5 } }
  )
  T.eq(
    "and the proxy is told no fixed rate, not one of 0",
    { rates().has_fixed_ramp_rate, rates().fixed_ramp_rate, rates().brightness_rate_min, rates().brightness_rate_max },
    { false, 0, 0, 65535 }
  )
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 5000 })
  T.eq("a level between two states is told at once", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 0 })
  serve(1000, 250)
  mark()
  proxy("OFF")
  T.eq("an off over the strip's 10 s", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 10000 })
  serve(11000, 250)
  mark()
  proxy("ON")
  T.eq("and an on over its 5 s", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 5000 })
end

--- driver.xml as the build writes it: the source's capabilities block filled from the light's profile.
local function builtXml()
  local f = assert(io.open(HERE .. "/../drivers/tplink_light/driver.xml", "rb"))
  local xml = f:read("*a")
  f:close()
  local caps = {}
  for _, cap in ipairs(Caps.static(Light.made[#Light.made].profile)) do
    caps[#caps + 1] = ("<%s>%s</%s>"):format(cap.key, tostring(cap.value), cap.key)
  end
  return (xml:gsub("<capabilities/>", "<capabilities>" .. table.concat(caps) .. "</capabilities>"))
end

T.section("the strip's own fades are read at each connect while Fades is Light, and not while it is Driver")
do
  walked({}, { ["Fades"] = "Light" })
  T.eq("a strip that connects with Fades on Light: its own fades are read", flying(), { "fades" })
  T.eq("which are all on: nothing is switched", #serve(1000, 250), 0)
  T.eq("and the proxy is told the fixed rate", rates(), lights(1000))
  -- The strip goes away, and comes back.
  run(4000)
  fail("Klap: request timed out")
  mark()
  run(5000)
  reply(info())
  T.eq("a strip that comes back is read again", flying(), { "fades" })
  serve(1000, 250)
  T.eq("and the proxy told the fixed rate with its capabilities", rates(), lights(1000))
  setProperty("Poll Rate (Seconds)", "10")
  shakeHands()
  mark()
  reply(info())
  T.eq("and when the backend is started again", flying(), { "fades" })
  T.eq("with no rate told until they are: the proxy lists the light's capabilities", rates(), {})
  serve(1000, 250)
  -- The strip is away when Driver is chosen.
  run(9000)
  fail("Klap: request timed out")
  mark()
  setProperty("Fades", "Driver")
  T.eq("Driver chosen while the strip is away: the proxy is told nothing of rates yet", rates(), {})
  run(10000)
  reply(info())

  walked({}, NO_POLLS)
  run(4000)
  T.eq("a strip that connects with Fades on Driver is asked nothing of its fades", flying(), {})
  setProperty("Fades", "Light")
  serve(1000, 250)
  mark()
  setProperty("Fades", "Driver")
  T.eq("choosing Driver again writes the strip nothing: its fades stay as they are", flying(), {})

  -- A light that has no such setting to read.
  walked({}, { ["Fades"] = "Light", ["Poll Rate (Seconds)"] = "300" })
  local read = table.remove(held, 1)
  if read then
    read.d:resolve({ error_code = -1001, result = {} })
  end
  T.eq(
    "fades that cannot be read: the proxy is told no stop, and no fixed rate",
    { rates().supports_brightness_stop, rates().has_fixed_ramp_rate, rates().brightness_rate_max },
    { false, false, 65535 }
  )
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 5000 })
  T.eq("a level is still one command", flying(), { { device_on = true, brightness = 40 } })
  T.eq("told at once, with no fade known to wait for", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 0 })
end

---------------------------------------------------------------------------
-- The light the driver finds, and what it shows
---------------------------------------------------------------------------

T.section("a Kasa bulb found after a strip the driver walked is sent the rate, as one found first")
do
  -- The driver goes from a strip it walked to a Kasa bulb.
  light()
  setProperty("Protocol", "Legacy")
  reply(sysinfo())
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  T.eq(
    "a Kasa bulb found after a strip is sent the rate, as one found first",
    flying(),
    { { on_off = 1, brightness = 30, ignore_default = 1, transition_period = 2000 } }
  )
  T.eq("and has no Fades to choose", hidden["Fades"], true)
end

T.section("dimming is declared in driver.xml, and turned off at run time for a light that only switches")
do
  local DIMMING = { "dimmer", "set_level", "supports_target", "supports_brightness_stop", "ramp_level" }
  local xml = builtXml()
  local declared = {}
  for _, capability in ipairs(DIMMING) do
    declared[#declared + 1] = xml:match("<" .. capability .. ">(%a+)</" .. capability .. ">")
  end
  T.eq("driver.xml declares each True", declared, { "True", "True", "True", "True", "True" })
  --- Each dimming capability the proxy was told with the light's first state.
  local function dimming()
    local out = {}
    local capabilities = told("DYNAMIC_CAPABILITIES_CHANGED", nil)[1] or {}
    for i, capability in ipairs(DIMMING) do
      out[i] = capabilities[capability]
    end
    return out
  end
  startDriver()
  shakeHands()
  reply(info())
  T.eq("a strip that dims keeps each", dimming(), { true, true, true, true, true })
  -- Bound to a TP-Link Outlet output, which only switches.
  C4:Bind(900, 1, C4:GetDeviceID(), 1, "TPLINK_LIGHT")
  startDriver()
  RFP.UPDATE_STATE(1, "UPDATE_STATE", {
    entity = SerializeSafe({ supported_color_modes = { require("constants").LightColorMode.COLOR_MODE_ON_OFF } }),
    state = SerializeSafe({ state = true }),
  })
  T.eq("a light bound to an outlet is told each is off", dimming(), { false, false, false, false, false })
  C4:Unbind(C4:GetDeviceID(), 1)
end

T.section("the TP-Link username and password are printed at no log level")
do
  local log = require("lib.logging")
  local USERNAME, PASSWORD = "someone@example.com", "a-word-kept-secret"
  light()
  -- Everything on, as Log Level "6 - Ultra" with Log Mode "Print and Log".
  log:setLogLevel("6 - Ultra")
  log:setLogMode("Print and Log")
  DEBUGPRINT = true
  local _, _, out = T.capture(function()
    setProperty("TP-Link Username", USERNAME)
    setProperty("TP-Link Password", PASSWORD)
  end)
  T.contains("each change is traced", out, "OPC.TP_Link_Username(<redacted>)")
  T.excludes("without the username", out, USERNAME)
  T.excludes("or the password", out, PASSWORD)
  T.eq("and the backend starts with them", status(), "Connecting (KLAP)...")
  -- The handler library prints the value of a property whose handler raises.
  function klap:configure()
    error("no transport")
  end
  _, _, out = T.capture(function()
    setProperty("TP-Link Username", USERNAME)
    setProperty("TP-Link Password", PASSWORD)
  end)
  T.contains("a start that raises is logged", out, "no transport")
  T.excludes("without the username", out, USERNAME)
  T.excludes("or the password", out, PASSWORD)
  DEBUGPRINT = false
  log:setLogLevel("3 - Info")
  log:setLogMode("Off")
end

T.section(
  "a light that stops answering is detected again from its third missed poll, and another device is not controlled"
)
do
  local listeners = 0
  function C4:CreateServer()
    listeners = listeners + 1
    return true
  end
  function C4:DestroyServer() end
  function C4:SendBroadcast() end
  light({ mac = "02-00-00-00-00-0C" }, { ["MAC Address"] = "" })
  T.eq("the light's MAC is shown", Properties["MAC Address"], "02:00:00:00:00:0C")
  T.falsy("in direct mode", hidden["MAC Address"])
  local handshakes = #klap.handshakes
  run(5000)
  fail("no answer")
  run(5000)
  fail("no answer")
  run(5000)
  T.eq("after two missed polls the next goes on the same session", flying(), { "poll" })
  T.eq("with no new handshake", #klap.handshakes, handshakes)
  fail("no answer")
  run(5000)
  T.eq("from the third the light's protocol is detected again", #klap.handshakes, handshakes + 1)
  shakeHands()
  reply(info({ mac = "02-00-00-00-00-0C" }))
  T.eq("and it connects", status(), "Connected (SMART)")
  T.eq("with no search for its address", listeners, 0)

  mark()
  run(5000)
  reply(info({ mac = "02-00-00-00-00-0D" }))
  T.eq("another device at the address starts a search", listeners, 1)
  T.eq("and the light is told as not answering", told("ONLINE_CHANGED", "STATE"), { false })
  mark()
  proxy("ON")
  T.eq("a command is sent to nothing", flying(), {})

  ShimRestartDirector()
  startDriver({ ["MAC Address"] = "" })
  shakeHands()
  reply(info({ mac = "02-00-00-00-00-0D" }))
  T.eq(
    "after a restart the light's MAC is kept: the other device is still not taken",
    status(),
    "Looking for the device on the network..."
  )
  T.eq("and shows no MAC of its own", Properties["MAC Address"], "")
  require("tplink.discovery").stop()
  require("lib.persist"):delete("discovery_mac")
end

T.section("an IP Address set by hand connects again there, to whichever light answers")
do
  local listeners = 0
  function C4:CreateServer()
    listeners = listeners + 1
    return true
  end
  function C4:DestroyServer() end
  function C4:SendBroadcast() end
  light({ mac = "02-00-00-00-00-0C" }, { ["MAC Address"] = "" })
  local handshakes = #klap.handshakes
  setProperty("IP Address", "192.0.2.25")
  T.eq("the light is detected again", #klap.handshakes, handshakes + 1)
  T.eq("at the new address", klap.config.ip, "192.0.2.25")
  shakeHands()
  reply(info({ mac = "02-00-00-00-00-0D" }))
  T.eq("another light there is taken: the address was set by hand", status(), "Connected (SMART)")
  T.eq("with no search for the old one", listeners, 0)
  T.eq("and its MAC is shown", Properties["MAC Address"], "02:00:00:00:00:0D")

  setProperty("IP Address", "")
  T.eq("with no IP Address the driver says what it needs", status(), "Bind to an outlet or set the IP Address property")
  T.eq("and asks for no handshake", #klap.handshakes, handshakes + 1)
  require("tplink.discovery").stop()
  require("lib.persist"):delete("discovery_mac")
end

T.section("a light bound to an outlet, or removed, stops looking for the light it had")
do
  local opened, closed = 0, 0
  function C4:CreateServer()
    opened = opened + 1
    return true
  end
  function C4:DestroyServer()
    closed = closed + 1
  end
  function C4:SendBroadcast() end
  light({ mac = "02-00-00-00-00-0C" }, { ["MAC Address"] = "" })
  run(5000)
  reply(info({ mac = "02-00-00-00-00-0D" }))
  T.eq("another device at the address starts a search", opened, 1)
  C4:Bind(900, 1, C4:GetDeviceID(), 1, "TPLINK_LIGHT")
  OnBindingChanged(1, "TPLINK_LIGHT", true, 900, 1)
  T.eq("a bind to an outlet ends it", closed, 1)
  T.truthy("and the status no longer says so", status() ~= "Looking for the device on the network...")
  run(10 * 60 * 1000)
  T.eq("with no search after it", opened, 1)
  C4:Unbind(C4:GetDeviceID(), 1)

  light({ mac = "02-00-00-00-00-0C" }, { ["MAC Address"] = "" })
  run(5000)
  reply(info({ mac = "02-00-00-00-00-0D" }))
  T.eq("a removed light's search", opened, 2)
  OnDriverDestroyed()
  T.eq("is ended", closed, 2)
  run(10 * 60 * 1000)
  T.eq("and none follows it", opened, 2)
  require("lib.persist"):delete("discovery_mac")
end

---------------------------------------------------------------------------
-- TPAP, and the driver's removal
---------------------------------------------------------------------------

local OFFERED = { port = 80, tls = 0, pake = { 2 } }

--- Refuse the KLAP login asked for last, as a light with Third-Party
--- Compatibility off does.
--- @param code? integer The HTTP status, 403 unless given.
local function refuseKlap(code)
  code = code or 403
  klap.handshakes[#klap.handshakes]:reject({
    error = "Klap: device refused the handshake (HTTP " .. code .. ")",
    code = code,
  })
end

--- Whether `status` was written as Driver Status since the mark.
local function wrote(status)
  for _, written in ipairs(statuses) do
    if written == status then
      return true
    end
  end
  return false
end

T.section("a KLAP login refused with 403 or 500 goes on to TPAP, and connects over it")
do
  for _, code in ipairs({ 403, 500 }) do
    startDriver()
    refuseKlap(code)
    T.eq("HTTP " .. code .. ": TPAP is tried", status(), "Connecting (TPAP)...")
    discovers[#discovers]:resolve(OFFERED)
    tpap.handshakes[#tpap.handshakes]:resolve(tpap)
    T.truthy("HTTP " .. code .. ": the light is asked over it", held[1] and held[1].transport == tpap)
    reply(info())
    T.eq("HTTP " .. code .. ": connected over it", status(), "Connected (TPAP)")
  end
end

T.section("a light that does not use TPAP is tried on the legacy protocol")
do
  startDriver()
  refuseKlap()
  discovers[#discovers]:resolve(nil)
  T.eq("the legacy protocol is tried", status(), "Connecting (Legacy)...")
  T.truthy("over the legacy port", held[1] and held[1].transport == legacy)
end

T.section("a legacy probe after TPAP fails with the KLAP refusal's reason: a 403's alone, a 500's with its own")
do
  startDriver()
  refuseKlap(403)
  discovers[#discovers]:resolve(nil)
  fail()
  T.truthy(
    "after a 403, the KLAP refusal is shown",
    wrote("Disconnected: Klap: device refused the handshake (HTTP 403)")
  )

  startDriver()
  refuseKlap(500)
  discovers[#discovers]:resolve(nil)
  fail()
  T.truthy(
    "after a 500, both reasons are shown",
    wrote("Disconnected: KLAP: Klap: device refused the handshake (HTTP 500) / Legacy: " .. TIMED_OUT)
  )
end

T.section("a light that answers neither schema over TPAP ends the attempt with no legacy probe")
do
  startDriver()
  refuseKlap()
  discovers[#discovers]:resolve(OFFERED)
  tpap.handshakes[#tpap.handshakes]:resolve(tpap)
  fail("TPAP: no answer to get_device_info")
  T.truthy("the IOT schema is asked over TPAP", held[1] and held[1].transport == tpap and asks(held[1]) == "poll")
  fail("TPAP: no answer to get_sysinfo")
  T.truthy("its reason is shown", wrote("Disconnected: TPAP: no answer to get_sysinfo"))
  T.eq("and no legacy probe goes out", flying(), {})
end

T.section("a login TPAP cannot make, a refused password or a lock ends the attempt with TPAP's reason")
do
  local refused = "TPAP: the TP-Link account password was refused; change TP-Link Password to try again"
  local cases = {
    {
      "a login it does not support",
      function()
        discovers[#discovers]:resolve({ port = 443, tls = 1, pake = { 2 } })
      end,
      "Disconnected: the light asks for a login this driver does not support yet;"
        .. " turn on Third-Party Compatibility in the Tapo or Kasa app",
    },
    {
      "a refused password",
      function()
        discovers[#discovers]:resolve(OFFERED)
        tpap.handshakes[#tpap.handshakes]:reject({ error = refused, refused = true })
      end,
      "Disconnected: " .. refused,
    },
    {
      "a lock",
      function()
        discovers[#discovers]:reject({ error = "TPAP: the device is locked after failed logins", locked = 30 })
      end,
      "Disconnected: TPAP: the device is locked after failed logins",
    },
  }
  for _, case in ipairs(cases) do
    startDriver()
    refuseKlap()
    case[2]()
    T.truthy(case[1] .. ": its reason is shown", wrote(case[3]))
    T.eq(case[1] .. ": and no legacy probe goes out", flying(), {})
  end
end

T.section("TPAP without the account says so")
do
  local asked = #discovers
  startDriver({ ["Protocol"] = "TPAP", ["TP-Link Password"] = "" })
  T.eq("it says what to set", status(), "Set the TP-Link Username and Password properties (required for TPAP)")
  T.eq("and asks nothing", #discovers, asked)
end

T.section("a TPAP probe replaced by another does nothing when it is answered")
do
  startDriver()
  refuseKlap()
  local discover = discovers[#discovers]
  EC.Reconnect()
  local logins = #tpap.handshakes
  discover:resolve(OFFERED)
  T.eq("no login follows", #tpap.handshakes, logins)
  T.eq("the new attempt is the one shown", status(), "Connecting (KLAP)...")
end

T.section("a removed driver's timers do not fire, and a probe answered after it does nothing")
do
  light()
  OnDriverDestroyed()
  T.eq("no timer is left", liveTimers(), {})
  local before = flying()
  run(20000)
  T.eq("and no poll goes out", flying(), before)
  startDriver()
  local handshake = klap.handshakes[#klap.handshakes]
  OnDriverDestroyed()
  mark()
  handshake:reject({ error = "Klap: connection reset" })
  T.eq("a probe failing after it writes no status", statuses, {})
end

T.eq("no timer or reply handler raised", errors, {})

T.finish()
