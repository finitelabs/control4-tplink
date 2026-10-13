--- A light reached directly, over KLAP or the legacy port: what it is sent, in
--- what order, and what the proxy is told when commands and polls overlap.
---
--- Driven through the driver's entry points on a virtual clock, with
--- SendToProxy captured. The transports are stand-ins that hold every reply
--- until the test gives it, as a light that takes its time does.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_light_direct.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local persist = require("lib.persist")

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

function C4:GetTime()
  return now
end

function C4:SetTimer(delayMs, callback, repeating)
  order = order + 1
  local t = { at = now + delayMs, order = order }
  local handle = newproxy(true)
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

function Transport:configure() end

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

package.loaded["lib.klap"] = {
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
package.loaded["lib.legacy"] = {
  new = function()
    legacy = setmetatable({ handshakes = {}, resets = 0 }, Transport)
    return legacy
  end,
}

local BULB_SERVICE = "smartlife.iot.smartbulb.lightingservice"

--- What a held request asks: "poll", or the params of the command it carries.
local function asks(request)
  local payload = request.payload
  if payload.method == "get_device_info" or Select(payload, "system", "get_sysinfo") then
    return "poll"
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

local sent, statuses, start = {}, {}, now

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

--- Load the driver afresh and start it with these properties over the usual.
local function startDriver(properties)
  queue, held = {}, {}
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
  end
  -- As OnDriverInit leaves it: no property's handler starts the backend.
  gInitialized = false
  OnDriverLateInit()
  mark()
end

--- Complete the KLAP handshake the driver asked for last.
local function shakeHands()
  klap.handshakes[#klap.handshakes]:resolve(klap)
end

--- A color strip connected over KLAP with the SMART schema, as info() has it.
local function light(fields)
  startDriver()
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
  RFP[command](PROXY, command, params or {})
end

--- Each `field` the proxy got with `command` since the mark; "at" is the ms.
local function told(command, field)
  local out = {}
  for _, s in ipairs(sent) do
    if s.binding == PROXY and s.command == command then
      out[#out + 1] = field == "at" and s.at or s.params[field]
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
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
  proxy("SET_LEVEL", { LEVEL = 30 })
  T.eq("a rate and then none: no transition", merged(), { device_on = true, brightness = 30 })
  proxy("SET_LEVEL", { LEVEL = 10 })
  proxy("SET_LEVEL", { LEVEL = 30 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
  T.eq("none and then a rate: the rate", merged(), { device_on = true, brightness = 80, transition_period = 3000 })
  proxy("SET_LEVEL", { LEVEL = 10 })
  proxy("SET_LEVEL", { LEVEL = 60 })
  proxy("OFF")
  T.eq("a level and then an off: the off alone", merged(), { device_on = false })
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
  T.eq(
    "a command and a poll that wait together: the command goes first",
    flying(),
    { { device_on = true, brightness = 40 } }
  )
  reply()
  T.eq("and the poll behind it, to read the light after it", flying(), { "poll" })
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
  T.eq("which what waits then follows", flying(), { { device_on = false } })
  reply()
  T.eq("and the poll behind it", flying(), { "poll" })
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
  T.eq("and that poll is given up on in its turn", flying()[2], { device_on = true })
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

T.section("a rated on from off is one request: no bare on goes ahead of it")
do
  light({ device_on = false })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq(
    "a level over a rate: the on, the level and the rate together",
    flying(),
    { { device_on = true, brightness = 50, transition_period = 2000 } }
  )
  reply()
  T.eq("with nothing behind it", flying(), {})
  light({ device_on = false })
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(30, 3000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a scene step over a rate: the same",
    flying(),
    { { device_on = true, brightness = 30, transition_period = 3000 } }
  )
  reply()
  T.eq("with nothing behind it", flying(), {})
  proxy("CLEAR_ALL_SCENES")
  bulb({ on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq(
    "a Kasa bulb: the same",
    flying(),
    { { on_off = 1, brightness = 50, ignore_default = 1, transition_period = 2000 } }
  )
  reply()
  T.eq("with nothing behind it", flying(), {})
end

T.section("a ramp's end sends the light nothing: it has held the level and the color since the command")
do
  -- Each ramp ends before the first poll is due, with nothing else in flight.
  light()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  reply()
  run(2200)
  T.eq("a level ramp: nothing is sent at its end", flying(), {})
  T.eq("where the proxy is told the level", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })
  mark()
  colorTarget(BLUE, 2000)
  reply()
  run(2200)
  T.eq("a color ramp: nothing is sent at its end", flying(), {})
  T.eq("where the proxy is told the color", told("LIGHT_COLOR_CHANGED", "at"), { 2000 })
  bulb()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  reply()
  run(2200)
  T.eq("a Kasa bulb's level ramp: nothing is sent at its end", flying(), {})
  T.eq("where the proxy is told the level", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })
end

T.section("a color set while a SMART light is off is kept, and goes out with the command that turns it on")
do
  local GREEN = xy(120, 50)
  local function colorsTold()
    return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")
  end
  light({ device_on = false })
  colorTarget(GREEN, 0)
  T.eq("the light, which would ignore it, is sent nothing", flying(), {})
  T.eq("the proxy is told the color", colorsTold(), { GREEN[1] })
  run(5000)
  mark()
  reply(info({ device_on = false }))
  T.eq("a poll that reads the color it had tells the proxy nothing", sent, {})
  proxy("ON")
  T.eq(
    "an on is one request, with the level and the color",
    flying(),
    { { device_on = true, brightness = 100, hue = 120, saturation = 50, color_temp = 0 } }
  )
  reply()
  proxy("OFF")
  reply()
  proxy("ON")
  T.eq("the on after that carries no color", flying(), { { device_on = true, brightness = 100 } })
  reply()

  light({ device_on = false })
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  colorTarget(GREEN, 2000)
  run(3000)
  T.eq("a color temperature and then a color over a rate: nothing is sent", flying(), {})
  proxy("SET_LEVEL", { LEVEL = 40 })
  T.eq(
    "and the on carries the later of the two",
    flying(),
    { { device_on = true, brightness = 40, hue = 120, saturation = 50, color_temp = 0 } }
  )
  reply()

  -- An off waiting behind a request, with a color set before it goes out.
  light()
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("OFF")
  colorTarget(GREEN, 0)
  reply()
  T.eq("an off and then a color, sent as one: the off alone goes", flying(), { { device_on = false } })
  reply()
  proxy("ON")
  T.eq("and the color with the on after it", Select(flying(), 1, "hue"), 120)
  reply()

  -- A scene step that turns the light off, waiting with a color either side.
  light()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(0, 0) })
  proxy("SET_LEVEL", { LEVEL = 50 })
  colorTarget(BLUE, 0)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  reply()
  T.eq("a color and then a scene's off, sent as one: the off goes", flying(), { { device_on = false } })
  reply()
  proxy("ON")
  T.eq("and the color, which never reached the light, with the on after it", Select(flying(), 1, "hue"), 240)
  reply()
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  colorTarget(GREEN, 0)
  reply()
  T.eq("a scene's off and then a color: the off goes", flying(), { { device_on = false } })
  reply()
  proxy("ON")
  reply()
  run(5000)
  colorTarget(BLUE, 0)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("the two made while a poll is in flight", flying(), { "poll" })
  reply(info())
  T.eq("go out as the off too", flying(), { { device_on = false } })
  reply()
  proxy("CLEAR_ALL_SCENES")

  -- A color for the off light that waits behind a request, with a poll.
  light({ device_on = false })
  proxy("ON")
  reply()
  proxy("OFF")
  colorTarget(GREEN, 0)
  run(5000)
  reply()
  T.eq("a color that waited and sends nothing lets the poll behind it go", flying(), { "poll" })
  reply(info({ device_on = false }))

  -- The backend started again, as a change of a connection property does.
  light({ device_on = false })
  colorTarget(GREEN, 0)
  setProperty("Poll Rate (Seconds)", "10")
  shakeHands()
  reply(info({ device_on = false }))
  proxy("ON")
  T.eq("a color kept is let go at a restart", flying(), { { device_on = true, brightness = 100 } })
  reply()

  -- A scene step that turns the light on in a color of its own.
  light({ device_on = false })
  colorTarget(GREEN, 0)
  local step = "<element><delay>0</delay><rate>0</rate><brightnessEnabled>true</brightnessEnabled>"
    .. "<brightness>50</brightness><colorEnabled>true</colorEnabled><colorX>%s</colorX><colorY>%s</colorY>"
    .. "<colorMode>0</colorMode></element>"
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = step:format(BLUE[1], BLUE[2]) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("an on that names a color goes out in its own", Select(flying(), 1, "hue"), 240)
  reply()
  proxy("CLEAR_ALL_SCENES")
  proxy("OFF")
  reply()
  proxy("ON")
  T.eq("and the one kept is let go", flying(), { { device_on = true, brightness = 100 } })
  reply()

  -- The light is turned on at its switch, or by another controller.
  light({ device_on = false })
  colorTarget(GREEN, 0)
  run(5000)
  mark()
  reply(info())
  T.eq("a light that came on by another hand is told as it is, in the color it had", colorsTold(), { 0 })
  proxy("SET_LEVEL", { LEVEL = 40 })
  T.eq("and the color kept for it is let go", flying(), { { device_on = true, brightness = 40 } })
  reply()

  -- Unmeasured on the IOT schema: a Kasa bulb is sent the color as before.
  bulb({ on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } })
  colorTarget(GREEN, 0)
  T.eq(
    "a Kasa bulb that is off is sent the color",
    flying(),
    { { on_off = 0, hue = 120, saturation = 50, color_temp = 0, ignore_default = 1 } }
  )
  reply()
end

T.section("a color temperature outside the light's range is told as the light takes it, once")
do
  local function kelvinTarget(kelvin)
    proxy(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = kelvin, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end
  local function pointsTold()
    return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")
  end
  -- The strip takes 2500 to 6500 K, and a color temperature is x here.
  light()
  kelvinTarget(2000)
  T.eq("2000 K: the light is sent the 2500 K it can do", flying(), { { device_on = true, color_temp = 2500 } })
  T.eq("and the proxy is told that temperature's point", pointsTold(), { 0.25 })
  reply()
  run(5000)
  mark()
  reply(info({ color_temp = 2500 }))
  T.eq("which the light's own report is no news of", sent, {})
  kelvinTarget(9000)
  T.eq("9000 K: the 6500 K point", pointsTold(), { 0.65 })
  reply()
  mark()
  kelvinTarget(4000)
  T.eq("4000 K, inside the range: as asked", pointsTold(), { 0.4 })
  reply()
  mark()
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.2,
    LIGHT_COLOR_TARGET_Y = 0.4,
    LIGHT_COLOR_TARGET_MODE = 1,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq("2000 K given as an xy: the 2500 K point", pointsTold(), { 0.25 })
  reply()
  mark()
  local step = "<element><delay>0</delay><rate>0</rate><colorEnabled>true</colorEnabled><colorX>0.9</colorX>"
    .. "<colorY>0.4</colorY><colorMode>1</colorMode></element>"
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = step })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("9000 K in a scene step: the 6500 K point", pointsTold(), { 0.65 })
  reply()
  proxy("CLEAR_ALL_SCENES")
end

T.eq("no timer or reply handler raised", errors, {})

T.finish()
