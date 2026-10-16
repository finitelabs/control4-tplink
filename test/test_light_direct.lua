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
-- gives one, or false for none.
local proxySetup = ""
function C4:GetProxyDevices()
  return 727
end
local uiRequest = C4.SendUIRequest
function C4:SendUIRequest(id, request, params)
  if request == "GET_SETUP" then
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
  RFP[command](PROXY, command, params or {})
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
  -- A strip the driver walks up: its first request is the fade's first step.
  light({ device_on = false })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq("a strip is sent nothing until the fade has a level for it", flying(), {})
  run(100)
  T.eq("and then an on at that level, with no bare on ahead of it", flying(), { { device_on = true, brightness = 3 } })
end

T.section("a ramp's end sends a light that fades by a command's time nothing: it has held both since the command")
do
  -- Each ramp ends before the first poll is due, with nothing else in flight.
  bulb()
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

---------------------------------------------------------------------------
-- The proxy's setup
---------------------------------------------------------------------------

--- An answer the proxy gave GET_SETUP on OS 4.3.0, as it came.
local function setupFile(name)
  local f = assert(io.open(HERE .. "/light_setup/" .. name, "rb"))
  local xml = f:read("*a")
  f:close()
  return xml
end

--- `xml` with the text of each tag in `tags` replaced, or the tag taken out
--- where it is given false.
local function withTags(xml, tags)
  for tag, value in pairs(tags) do
    xml =
      xml:gsub("<" .. tag .. ">.-</" .. tag .. ">", value and ("<" .. tag .. ">" .. value .. "</" .. tag .. ">") or "")
  end
  return xml
end

local SETUP_KEYS = {
  "color_on_mode",
  "brightness_on_mode",
  "brightness_on_mode_preset",
  "brightness_rate_default",
  "color_rate_default",
}

--- Forget what the driver stores of the proxy's on modes, presets and rates.
local function forgetSetup()
  for _, key in ipairs({ "color_presets", "brightness_presets", "previous_color" }) do
    persist:delete(key)
  end
  for _, key in ipairs(SETUP_KEYS) do
    persist:delete(key)
  end
end

--- Answer everything in flight, and whatever goes out behind it.
local function settle()
  while held[1] do
    reply()
  end
end

--- The one command in flight, which is then answered.
local function answered()
  local command = flying()[1]
  reply()
  return command
end

local function colorsTold()
  return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")
end

local CCT_MODE = 1

T.section("a light the proxy never sent its Color On Mode reads it from the proxy's setup at start")
do
  -- The proxy sends a mode when it changes and a preset when it is made: a
  -- light left in the mode it was made with has its presets and no mode.
  forgetSetup()
  light({ device_on = false })
  for _, p in ipairs({
    { 1, "On Color", 0.380438, 0.376746 },
    { 2, "Dim Color", 0.526676, 0.413297 },
    { 10, "Previous On", 0.497642, 0.415248 },
  }) do
    proxy(
      "UPDATE_COLOR_PRESET",
      { COMMAND = "ADDED", ID = p[1], NAME = p[2], COLOR_X = p[3], COLOR_Y = p[4], COLOR_MODE = CCT_MODE }
    )
  end
  proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "ADDED", ID = 10, NAME = "Previous On", LEVEL = 20 })
  proxySetup = setupFile("setup-607.xml")
  light({ device_on = false })
  proxy("SET_LEVEL", { LEVEL = 50 })
  -- Dim-To-Warm between the device's On Color and Dim Color: 3804 K and
  -- 5267 K here, 4536 K half way.
  T.eq(
    "a level carries the Dim-To-Warm mix as a color temperature",
    answered(),
    { device_on = true, brightness = 50, color_temp = 4536 }
  )
  T.eq("and the proxy is told it", colorsTold(), { 0.453557 })
  proxy(
    "UPDATE_COLOR_PRESET",
    { COMMAND = "MODIFIED", ID = 1, NAME = "On Color", COLOR_X = 0.3, COLOR_Y = 0.4, COLOR_MODE = CCT_MODE }
  )
  mark()
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq(
    "an edit of the On Color alone then moves the on color",
    answered(),
    { device_on = true, brightness = 100, color_temp = 3000 }
  )
  T.eq("which the proxy is told", colorsTold(), { 0.3 })
end

T.section("a preset the setup names is found by its id and its origin together")
do
  -- This light's Dim-To-Warm is between the Color Agent's Sunset (8) and Blue
  -- Bonnet (10), and the device's own preset 10 is Previous On, which the
  -- driver has stored.
  forgetSetup()
  proxySetup = ""
  light({ device_on = false })
  proxy(
    "UPDATE_COLOR_PRESET",
    { COMMAND = "ADDED", ID = 10, NAME = "Previous On", COLOR_X = 0.305692, COLOR_Y = 0.189781, COLOR_MODE = 0 }
  )
  proxySetup = setupFile("setup-626.xml")
  light({ device_on = false })
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "the mix is between the Color Agent's two",
    answered(),
    { device_on = true, brightness = 50, hue = 135, saturation = 23, color_temp = 0 }
  )
  T.eq("which the proxy is told", colorsTold(), { 0.142639 + (0.608506 - 0.142639) * 0.5 })
end

T.section("a setup with no fade preset is Previous for the device's preset 10 and a preset for any other")
do
  local noFade = { light_color_on_mode_fade_preset_id = 0, light_color_on_mode_fade_preset_origin = 0 }
  --- A light started with `setup`, on in green and then off.
  local function offInGreen(setup)
    forgetSetup()
    proxySetup = setup
    light()
    colorTarget(xy(120, 50), 0)
    reply()
    proxy("OFF")
    reply()
  end
  local setup = withTags(setupFile("setup-607.xml"), noFade)
  offInGreen(withTags(setup, { light_color_on_mode_preset_id = 10 }))
  proxy("ON")
  T.eq(
    "Previous: an on is in the color the light went off in",
    answered(),
    { device_on = true, brightness = 100, hue = 120, saturation = 50, color_temp = 0 }
  )
  offInGreen(setup)
  proxy("ON")
  T.eq("a preset: an on is in the On Color", answered(), { device_on = true, brightness = 100, color_temp = 3804 })
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("and a level after it carries no color", answered(), { device_on = true, brightness = 50 })
end

T.section("a setup that cannot be read, or that names no on mode, leaves what the driver has stored")
do
  --- What the driver has stored under each key the setup can write.
  local function stored()
    local out = {}
    for _, key in ipairs(SETUP_KEYS) do
      out[key] = persist:get(key, false)
    end
    return out
  end
  forgetSetup()
  proxySetup = ""
  light({ device_on = false })
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = 0.6,
    COLOR_PRESET_COLOR_Y = 0.3,
    COLOR_PRESET_COLOR_MODE = 0,
    COLOR_FADE_PRESET_ID = 2,
    COLOR_FADE_PRESET_ORIGIN = 1,
    COLOR_FADE_PRESET_COLOR_X = 0.14,
    COLOR_FADE_PRESET_COLOR_Y = 0.1,
    COLOR_FADE_PRESET_COLOR_MODE = 0,
  })
  proxy("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 3, BRIGHTNESS_PRESET_LEVEL = 40 })
  proxy("UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = 1234 })
  local before = stored()
  local setup, none = setupFile("setup-607.xml"), {}
  for _, tag in ipairs({
    "light_color_on_mode_preset_id",
    "light_color_on_mode_preset_origin",
    "light_color_on_mode_fade_preset_id",
    "light_color_on_mode_fade_preset_origin",
    "light_brightness_on_mode_preset_id",
    "light_brightness_rate_default",
    "light_color_rate_default",
  }) do
    none[tag] = false
  end
  for _, c in ipairs({
    { "no answer", false },
    { "an empty answer", "" },
    { "an answer that is not whole", setup:sub(1, 2000) },
    { "a setup with none of the tags", withTags(setup, none) },
  }) do
    proxySetup = c[2]
    light({ device_on = false })
    T.eq(c[1] .. ": nothing stored changes", stored(), before)
  end
  -- A preset the setup names and does not list has no color or level to
  -- store: the mode stored stands.
  for _, c in ipairs({
    { "an on preset that is not listed", "color_on_mode", { light_color_on_mode_preset_id = 99 } },
    { "a fade preset that is not listed", "color_on_mode", { light_color_on_mode_fade_preset_id = 99 } },
    { "no fade origin", "color_on_mode", { light_color_on_mode_fade_preset_origin = false } },
    { "a brightness preset that is not listed", "brightness_on_mode", { light_brightness_on_mode_preset_id = 99 } },
  }) do
    local had = persist:get(c[2], false)
    proxySetup = withTags(setup, c[3])
    light({ device_on = false })
    T.eq(c[1] .. ": the mode stored stands", persist:get(c[2], false), had)
  end
end

T.section("the brightness on mode and the default rates are read from the proxy's setup too")
do
  -- The mode as Previous On, whose level the proxy has at 20 %, and both
  -- rates at 750 ms.
  forgetSetup()
  proxySetup = withTags(setupFile("setup-607.xml"), { light_brightness_on_mode_preset_id = 10 })
  light({ device_on = false })
  proxy("ON")
  T.eq("an on goes to the level of the mode's preset", answered().brightness, 20)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80 })
  T.eq("a target with no rate ramps at the proxy's default", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 750 })
  run(1000)
  settle()
  mark()
  proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.5 })
  T.eq("and a color with no rate fades at it", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"), { 750 })
  run(1000)
  settle()
  -- The proxy sends the mode when it changes, and a preset when it is edited:
  -- the on level follows both.
  --- An edit of preset 10 and then its removal, on a light whose mode is that
  --- preset `how`.
  local function follows(how)
    proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = 35 })
    proxy("OFF")
    settle()
    proxy("ON")
    T.eq("a mode " .. how .. ": an edit of its preset moves the on level", answered().brightness, 35)
    proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "REMOVED", ID = 10 })
    proxy("OFF")
    settle()
    proxy("ON")
    T.eq("a mode " .. how .. ": with its preset removed an on goes to the Default On level", answered().brightness, 100)
  end
  follows("read from the setup")
  forgetSetup()
  proxySetup = ""
  light({ device_on = false })
  proxy("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 10, BRIGHTNESS_PRESET_LEVEL = 20 })
  follows("sent by the proxy")
  -- The two default rates are one setting to this light, so either of the
  -- setup's is both.
  for _, tag in ipairs({ "light_brightness_rate_default", "light_color_rate_default" }) do
    forgetSetup()
    proxySetup = withTags(setupFile("setup-607.xml"), { [tag] = false })
    light({ device_on = false })
    T.eq(
      "a setup without " .. tag .. ": both rates are the other's",
      { persist:get("brightness_rate_default", false), persist:get("color_rate_default", false) },
      { 750, 750 }
    )
  end
end

T.section("the Tapo strip's own proxy: Dim-To-Warm between two presets of one color, and rates of 750 ms")
do
  -- setup-727.xml is what this driver's proxy answered on the first hardware
  -- run, where the driver held no Color On Mode and a rate of 500 ms.
  forgetSetup()
  proxySetup = setupFile("setup-727.xml")
  light({ device_on = false })
  proxy("ON")
  T.eq(
    "an on is at full, in the On Color",
    answered(),
    { device_on = true, brightness = 100, hue = 152, saturation = 40, color_temp = 0 }
  )
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30 })
  T.eq("a level with no rate fades over the proxy's 750 ms", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 750 })
  run(100)
  T.eq(
    "in steps that name no color: the two Dim-To-Warm colors are one",
    answered(),
    { device_on = true, brightness = 91 }
  )
  forgetSetup()
  proxySetup = ""
end

---------------------------------------------------------------------------
-- A fade the driver makes itself
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

--- Whether each command went out `ms` after the one before it.
local function spaced(commands, ms)
  for i = 2, #commands do
    if commands[i].at - commands[i - 1].at ~= ms then
      return false
    end
  end
  return true
end

--- A scene element fading to a level and a color over `rate` ms.
local function colorStep(level, color, rate)
  local step = "<element><delay>0</delay><rate>%d</rate><brightnessEnabled>true</brightnessEnabled>"
    .. "<brightness>%d</brightness><colorEnabled>true</colorEnabled><colorX>%s</colorX><colorY>%s</colorY>"
    .. "<colorMode>0</colorMode></element>"
  return step:format(rate, level, color[1], color[2])
end

local TOP, PRESS, RELEASE = 0, 1, 0

T.section("a level with a rate is walked there in steps, each sent as the strip answers the one before")
do
  --- Where a ramp from 5 to 100 % over 10 s is `ms` in, as a whole level.
  local function line(ms)
    return math.floor(5 + 95 * math.min(ms, 10000) / 10000 + 0.5)
  end
  --- Whether each step names the level the line is at as it is sent.
  local function onTheLine(steps)
    for _, step in ipairs(steps) do
      if step.sent.brightness ~= line(step.at) or step.sent.device_on ~= true then
        return false
      end
    end
    return true
  end
  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  T.eq(
    "5 to 100 % over 10 s: the proxy is told the ramp and its rate",
    told("LIGHT_BRIGHTNESS_CHANGING"),
    { { LIGHT_BRIGHTNESS_CURRENT = 5, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 } }
  )
  T.eq("the strip is sent nothing while the level has not moved", flying(), {})
  local steps = serve(11000, 250)
  T.eq("its first step is the first level on, with no fade time", steps[1], {
    at = 100,
    sent = { device_on = true, brightness = 6 },
  })
  T.check("a strip that takes 250 ms is sent a step every 250 ms", spaced(steps, 250), T.show(each(steps, "at")))
  T.eq("41 in all", #steps, 41)
  T.check("each the level the line is at as it is sent", onTheLine(steps), T.show(each(steps, "brightness")))
  T.eq("the last is the target itself", Select(steps, #steps, "sent"), { device_on = true, brightness = 100 })
  T.eq("never two requests in flight", busiest, 1)
  T.eq("the proxy is told the level once, at the ramp's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 10000 })
  T.eq("which is the target", levels(), { 100 })
  T.eq("and nothing is sent after", serve(3000, 250), {})

  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  steps = serve(13000, 1200)
  T.check("a strip that takes 1200 ms is sent a step every 1200 ms", spaced(steps, 1200), T.show(each(steps, "at")))
  T.eq("10 in all, each several levels on", each(steps, "brightness"), { 6, 17, 29, 40, 52, 63, 74, 86, 97, 100 })
  T.eq("the proxy is told the level at the ramp's end all the same", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 10000 })
  T.eq("and the target goes out when the strip has answered the step before", Select(steps, #steps, "at"), 10900)
  T.eq("never two requests in flight", busiest, 1)

  -- A strip that answers at once is not sent a step for each answer.
  walked({ brightness = 1 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  steps = serve(3000, 20)
  T.check(
    "a strip that takes 20 ms is sent a step every 100 ms, and no more",
    spaced(steps, 100),
    T.show(each(steps, "at"))
  )
  T.eq(
    "20 in all, the last the target at the ramp's end",
    { #steps, Select(steps, #steps, "at"), strip.brightness },
    { 20, 2000, 100 }
  )
  local timers = order
  run(60000)
  T.eq("and with the fade over the driver looks for no next step", order - timers, 0)
  walked({ brightness = 1 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 1950 })
  steps = serve(3000, 20)
  T.eq(
    "a ramp's last step goes at the ramp's end, however soon after the one before",
    { Select(steps, #steps - 1, "at"), Select(steps, #steps, "at"), strip.brightness },
    { 1900, 1950, 100 }
  )
end

T.section("a rate of 0, and a change of one level over any rate, are one command")
do
  walked({ brightness = 50 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 0 })
  T.eq("a rate of 0: the level at once", flying(), { { device_on = true, brightness = 80 } })
  T.eq("which the proxy is told at once", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 0 })
  T.eq("and nothing follows", each(serve(3000, 250), "brightness"), { 80 })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 81, RATE = 4000 })
  T.eq("one level over 4 s: one command", each(serve(6000, 250), "brightness"), { 81 })
  T.eq("and the level told at the ramp's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 4000 })
  mark()
  colorTarget(BLUE, 0)
  T.eq("a color with a rate of 0: the color at once", flying(), {
    { device_on = true, hue = 240, saturation = 100, color_temp = 0 },
  })
  T.eq("and nothing follows", #serve(3000, 250), 1)
end

T.section("a stop stops the steps: the strip is left at the last one sent, and that level is told")
do
  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  serve(5000, 250)
  T.eq("half way through 5 to 100 % a step is in flight", flying(), { { device_on = true, brightness = 51 } })
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop tells the level of that step", levels(), { 51 })
  T.eq("and sends nothing", flying(), { { device_on = true, brightness = 51 } })
  T.eq("no step follows", #serve(8000, 250), 1)
  T.eq("so the strip holds the level told", strip.brightness, 51)
  T.eq("and the proxy is told nothing at what was the ramp's end", levels(), { 51 })

  -- A ramp that replaces a fade starts where the strip is, behind the line.
  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  serve(5000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 60000 })
  T.eq(
    "a ramp that replaces a fade starts from the step the strip was last sent",
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    { 51 }
  )
  proxy("SET_BRIGHTNESS_STOP")
  serve(1000, 250)
  T.eq(
    "so a stop before its first step tells the level the strip holds",
    { levels(), strip.brightness },
    { { 51 }, 51 }
  )

  -- A held button is a ramp that the release stops.
  walked({ brightness = 30 }, NO_POLLS)
  proxy("SET_HOLD_RATE_UP", { RATE = 5000 })
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  T.eq("Top held from 30 %: a ramp to full at the hold rate", told("LIGHT_BRIGHTNESS_CHANGING"), {
    { LIGHT_BRIGHTNESS_CURRENT = 30, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 },
  })
  local steps = serve(2500, 250)
  T.eq("in steps as the strip answers", each(steps, "brightness"), { 31, 35, 38, 42, 45, 49, 52, 56, 59 })
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE })
  T.eq("its release half way tells the level of the step last sent", levels(), { 63 })
  T.eq("and nothing follows that step", each(serve(4000, 250), "brightness"), { 63 })
end

T.section("a fade to off ends with the off alone, and the next on from Control4 names its own level")
do
  -- The strip takes no level with an off, and one sent ahead of it would show.
  local BOTTOM, CLICK = 1, 2
  walked({ brightness = 51 }, NO_POLLS)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(110)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = CLICK })
  local steps = serve(3000, 250)
  T.eq("Bottom pressed and clicked from 51 %: the press's step, the click's, and the off alone", {
    each(steps, "brightness"),
    Select(steps, #steps, "sent"),
  }, { { 49, 27, 1 }, { device_on = false } })
  T.eq("nothing follows the off", #serve(10000, 250), 0)
  T.eq("so the strip is off at the last step's level", { strip.device_on, strip.brightness }, { false, 1 })
  proxy("ON")
  T.eq("the next On is the On level itself", flying(), { { device_on = true, brightness = 100 } })
  serve(1000, 250)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(110)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = CLICK })
  serve(3000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  T.eq("and a ramped on names a level from its first step", Select(serve(3000, 250), 1, "sent"), {
    device_on = true,
    brightness = 3,
  })
end

T.section("a color with a rate is walked there too")
do
  -- Red to blue is hue 0 to 240 here, a straight line in x.
  walked({}, NO_POLLS)
  colorTarget(BLUE, 10000)
  T.eq("red to blue over 10 s: the proxy is told the fade and its rate", told("LIGHT_COLOR_CHANGING"), {
    {
      LIGHT_COLOR_CURRENT_X = 0,
      LIGHT_COLOR_CURRENT_Y = 1,
      LIGHT_COLOR_CURRENT_COLOR_MODE = 0,
      LIGHT_COLOR_TARGET_X = BLUE[1],
      LIGHT_COLOR_TARGET_Y = BLUE[2],
      LIGHT_COLOR_TARGET_COLOR_MODE = 0,
      LIGHT_COLOR_TARGET_COLOR_RATE = 10000,
      LIGHT_COLOR_TARGET_RATE = 10000,
    },
  })
  local steps = serve(11000, 250)
  T.eq("its first step is the color the line has got to, with no fade time", steps[1], {
    at = 100,
    sent = { device_on = true, hue = 2, saturation = 100, color_temp = 0 },
  })
  T.check("a step as the strip answers the one before", spaced(steps, 250), T.show(each(steps, "at")))
  local onTheLine = true
  for _, step in ipairs(steps) do
    onTheLine = onTheLine and step.sent.hue == math.floor(240 * math.min(step.at, 10000) / 10000 + 0.5)
  end
  T.check("each the hue the line is at as it is sent", onTheLine, T.show(each(steps, "hue")))
  T.eq("the last is the target itself", Select(steps, #steps, "sent"), {
    device_on = true,
    hue = 240,
    saturation = 100,
    color_temp = 0,
  })
  T.eq("the proxy is told the color once, at the fade's end", told("LIGHT_COLOR_CHANGED", "at"), { 10000 })
  T.eq("which is the target", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
  T.eq("never two requests in flight", busiest, 1)

  walked({}, NO_POLLS)
  colorTarget(BLUE, 10000)
  serve(5000, 250)
  T.eq("half way a step is in flight", Select(flying(), 1, "hue"), 116)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a stop tells the color of that step", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] * 0.485 })
  T.eq("and no step follows it", each(serve(8000, 250), "hue"), { 116 })
  T.eq("so the strip holds that color past the fade's end", strip.hue, 116)
  colorTarget(BLUE, 10000)
  serve(5000, 250)
  mark()
  colorTarget(xy(0, 100), 60000)
  T.eq(
    "a color fade that replaces another starts from the color the strip was last sent",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] * 0.485 + (BLUE[1] - BLUE[1] * 0.485) * 0.495 }
  )

  -- Hue 0 to 3: the fade's end is nearer the step before it than two colors
  -- the driver tells apart.
  walked({}, NO_POLLS)
  colorTarget(xy(3, 100), 2000)
  T.eq("a fade of a few degrees ends on its color all the same", each(serve(3000, 250), "hue"), { 2, 3 })

  walked({}, NO_POLLS)
  colorTarget(BLUE, 10000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  local steps = serve(3000, 250)
  T.eq("a ramp to off beside a color fade ends with the off", Select(steps, #steps, "sent"), { device_on = false })
  T.eq("and the strip is off", strip.device_on, false)

  -- A color for a strip that is off has nothing to walk: it is kept for the on.
  walked({ device_on = false }, NO_POLLS)
  colorTarget(BLUE, 2000)
  T.eq("a color over a rate for a strip that is off: nothing is sent", serve(3000, 250), {})
  proxy("ON")
  T.eq("and the on carries it", flying(), {
    { device_on = true, brightness = 100, hue = 240, saturation = 100, color_temp = 0 },
  })

  -- A strip the driver walks up from off is off until the walk's first level.
  walked({ device_on = false }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 60000 })
  run(50)
  colorTarget(BLUE, 0)
  T.eq("a color before a fade up from off has sent its first level: no on without a level", flying(), {
    { device_on = true, brightness = 1, hue = 240, saturation = 100, color_temp = 0 },
  })
  T.eq("it goes with the fade's first level, sent as the color comes", serve(1000, 250)[1].at, 50)
  walked({ device_on = false }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 60000 })
  run(50)
  colorTarget(BLUE, 5000)
  steps = serve(1000, 250)
  T.eq("a color fading beside it: the first request is the first level, sent as the color comes", steps[1], {
    at = 50,
    sent = { device_on = true, brightness = 1 },
  })
  T.eq("and the color's steps follow", each(steps, "hue"), { 12, 24 })

  -- Nor is it on at a level the fade has reached and not yet sent.
  walked({ device_on = false })
  run(4950)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 60000 })
  run(350)
  colorTarget(BLUE, 0)
  T.eq("a color while the fade's first level waits for a poll's answer waits with it", flying(), { "poll" })
  T.eq("and goes with that level", Select(serve(1000, 250), 1, "sent"), {
    device_on = true,
    brightness = 1,
    hue = 240,
    saturation = 100,
    color_temp = 0,
  })

  -- And one the driver has walked to off is off, though its ramp runs on.
  walked({ brightness = 2 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 60000 })
  steps = serve(50000, 250)
  T.eq(
    "2 % to off over 60 s: the off is sent 45 s in",
    { each(steps, "at"), strip.device_on },
    { { 15100, 45050 }, false }
  )
  mark()
  colorTarget(BLUE, 0)
  T.eq("a color after the off, before the ramp's end, turns no strip on: it is kept", flying(), {})
  serve(15000, 250)
  T.eq("so the strip is off at the ramp's end, as the proxy is told", { strip.device_on, levels() }, { false, { 0 } })
  proxy("ON")
  T.eq("and the next on carries the color", Select(flying(), 1, "hue"), 240)
end

T.section("a scene step with a ramp time fades: its level and its color walked together")
do
  walked({ brightness = 20 }, NO_POLLS)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(80, BLUE, 4000) })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  local steps = serve(5000, 250)
  T.eq("20 to 80 % and red to blue over 4 s: a step names both", steps[1], {
    at = 100,
    sent = { device_on = true, brightness = 22, hue = 6, saturation = 100, color_temp = 0 },
  })
  T.check("a step as the strip answers the one before", spaced(steps, 250), T.show(each(steps, "at")))
  T.eq("the last is the step's own level and color", Select(steps, #steps, "sent"), {
    device_on = true,
    brightness = 80,
    hue = 240,
    saturation = 100,
    color_temp = 0,
  })
  T.eq("the level is told once, at the step's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 4000 })
  T.eq("and the color", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  proxy("CLEAR_ALL_SCENES")

  -- A level the step names and no ramp walks is not dropped with the rest.
  walked({ brightness = 80 }, NO_POLLS)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(80, BLUE, 4000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("a step to the level the strip is at, and to blue over 4 s: the level goes at once", flying(), {
    { device_on = true, brightness = 80 },
  })
  T.eq("and the color in steps", Select(serve(5000, 250), 2, "sent"), {
    device_on = true,
    hue = 15,
    saturation = 100,
    color_temp = 0,
  })
  proxy("CLEAR_ALL_SCENES")

  -- From off there is no color to fade from.
  walked({ device_on = false }, NO_POLLS)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(60, BLUE, 3000) })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a step that fades the strip up from off: the proxy is told its color at once",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 0 }
  )
  steps = serve(4000, 250)
  T.eq("the strip comes on in it, at the fade's first level", steps[1], {
    at = 100,
    sent = { device_on = true, brightness = 2, hue = 240, saturation = 100, color_temp = 0 },
  })
  T.eq("and the steps after name the level alone", Select(steps, 2, "sent"), { device_on = true, brightness = 7 })
  T.eq("up to the step's level", Select(steps, #steps, "sent"), { device_on = true, brightness = 60 })
  proxy("CLEAR_ALL_SCENES")

  -- A strip that only switches has nothing to walk.
  startDriver(NO_POLLS)
  shakeHands()
  reply({ device_on = true })
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(0, 3000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("a step with a ramp time for a strip that only switches: the off, at once", flying(), { { device_on = false } })
  proxy("CLEAR_ALL_SCENES")
end

T.section(
  "the color a ramp carries goes with its steps: the color the strip turns on in, or the Dim-To-Warm color for each level"
)
do
  local ON, DIM = xy(60, 20), xy(30, 80)
  --- A Color On Mode of the preset ON, with Dim-To-Warm down to DIM if `fade`.
  local function onMode(fade)
    proxy("UPDATE_COLOR_ON_MODE", {
      COLOR_PRESET_ID = 1,
      COLOR_PRESET_ORIGIN = 1,
      COLOR_PRESET_COLOR_X = ON[1],
      COLOR_PRESET_COLOR_Y = ON[2],
      COLOR_PRESET_COLOR_MODE = 0,
      COLOR_FADE_PRESET_ID = fade and 2 or 0,
      COLOR_FADE_PRESET_ORIGIN = fade and 1 or 0,
      COLOR_FADE_PRESET_COLOR_X = DIM[1],
      COLOR_FADE_PRESET_COLOR_Y = DIM[2],
      COLOR_FADE_PRESET_COLOR_MODE = 0,
    })
  end
  forgetSetup()
  walked({ device_on = false }, NO_POLLS)
  onMode(false)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  local steps = serve(5000, 250)
  T.eq("a ramped on with a preset On color: the strip comes on in it", Select(steps, 1, "sent"), {
    device_on = true,
    brightness = 3,
    hue = 60,
    saturation = 20,
    color_temp = 0,
  })
  T.eq("and the steps after name the level alone", Select(steps, 2, "sent"), { device_on = true, brightness = 9 })
  T.eq("the proxy is told the color at the ramp's end", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  proxy("OFF")
  serve(1000, 250)
  colorTarget(BLUE, 0)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 10, RATE = 30000 })
  run(100)
  T.eq("off in blue, a slow on's first step, at 1 %, carries it too", flying(), {
    { device_on = true, brightness = 1, hue = 60, saturation = 20, color_temp = 0 },
  })
  serve(31000, 250)
  proxy("OFF")
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(90)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop before the on's first step: the strip, sent nothing, is told as off",
    { flying(), levels() },
    { {}, { 0 } }
  )
  T.eq(
    "and in the color it has, to end the change to the On color it was told of",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )
  -- Off in blue, a ramped on in the On color, and a color before its first step.
  colorTarget(BLUE, 0)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  mark()
  colorTarget(xy(120, 50), 2000)
  T.eq(
    "a color before the on's first step fades from the color the strip has, not the On color it was never sent",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] }
  )
  serve(5000, 250)
  proxy("OFF")
  serve(1000, 250)
  -- Off in blue, a ramped on in the On color, and a level a second into it.
  colorTarget(BLUE, 0)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  serve(1000, 250)
  proxy("SET_LEVEL", { LEVEL = 50 })
  serve(1000, 250)
  mark()
  colorTarget(xy(120, 50), 2000)
  T.eq(
    "a level command a second into the on leaves the strip in the On color it came on in",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )

  forgetSetup()
  walked({ device_on = false }, NO_POLLS)
  onMode(true)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  steps = serve(2000, 250)
  T.eq("with Dim-To-Warm it comes on in the color for its first level", Select(steps, 1, "sent"), {
    device_on = true,
    brightness = 3,
    hue = 31,
    saturation = 78,
    color_temp = 0,
  })
  T.eq("and each step is in the color for its own", Select(steps, #steps, "sent"), {
    device_on = true,
    brightness = 40,
    hue = 42,
    saturation = 56,
    color_temp = 0,
  })
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop tells the level of the step last sent", levels(), { 46 })
  T.eq(
    "and its Dim-To-Warm color, not the ramp's last",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { DIM[1] + (ON[1] - DIM[1]) * 0.46 }
  )
  serve(1000, 250)
  T.eq("which is the color the strip holds", { strip.hue, strip.saturation }, { 44, 52 })

  -- At full in the On color, the Dim-To-Warm color for 100 %.
  walked({ brightness = 100, hue = 60, saturation = 20 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 10, RATE = 4000 })
  T.eq("a dim with Dim-To-Warm sends no color ahead of its steps", flying(), {})
  steps = serve(1000, 250)
  T.eq("its first step is the first level down, in that level's color", Select(steps, 1, "sent"), {
    device_on = true,
    brightness = 98,
    hue = 59,
    saturation = 21,
    color_temp = 0,
  })
  colorTarget(BLUE, 0)
  T.eq("a color set during the dim is the strip's from there: no step after it names another", {
    Select(flying(), 1, "hue"),
    each(serve(2000, 250), "hue"),
  }, { 54, { 54, 240 } })
  serve(2000, 250)
  T.eq("to the dim's end", { strip.brightness, strip.hue }, { 10, 240 })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  steps = serve(3000, 250)
  T.eq("a ramp to off with Dim-To-Warm ends with the off, alone", Select(steps, #steps, "sent"), { device_on = false })

  -- A stop tells the color a step carried only while no other was set since.
  walked({ brightness = 100 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 10, RATE = 4000 })
  serve(1000, 250)
  colorTarget(BLUE, 0)
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop after a color was set during the dim tells the level and no color: the strip is in the one set",
    { levels(), told("LIGHT_COLOR_CHANGED") },
    { { 58 }, {} }
  )

  -- A scene step that sets a level alone fades the color to the formula's
  -- for that level, from one set since: a ramp of the color's own.
  walked({ brightness = 50, hue = 61, saturation = 21 }, NO_POLLS)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(100, 4000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("beside a color fade of its own a level's steps name no Dim-To-Warm color", each(serve(1000, 250), "hue"), {})
  proxy("CLEAR_ALL_SCENES")

  -- Two Dim-To-Warm colors six levels apart are one color to the driver.
  forgetSetup()
  walked({ brightness = 90, hue = 57, saturation = 20 }, NO_POLLS)
  DIM = xy(30, 20)
  onMode(true)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  serve(3000, 250)
  T.eq("a ramp ends in the color for its last level, however near the step before", { strip.brightness, strip.hue }, {
    100,
    60,
  })
  walked({ device_on = false }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  steps = serve(3000, 20)
  T.eq(
    "from off, a step names the color only once it has moved on from the last sent, and the last is the target's",
    { #steps, each(steps, "hue") },
    { 20, { 32, 35, 38, 41, 44, 47, 50, 53, 56, 59, 60 } }
  )
  forgetSetup()
end

T.section("with Dim-To-Warm a strip that is on walks to the color the proxy is told of, and a fade to off walks none")
do
  -- The strip's own proxy: Dim-To-Warm between two presets of one color.
  local ON = { 0.423358, 0.398951 }
  forgetSetup()
  proxySetup = setupFile("setup-727.xml")
  walked({ brightness = 40 }, NO_POLLS)
  colorTarget(BLUE, 0)
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 8000 })
  local fade = told("LIGHT_COLOR_CHANGING")[1] or {}
  T.eq(
    "40 to 80 % over 8 s in blue: the proxy is told a fade from blue to the On color over 8 s",
    { fade.LIGHT_COLOR_CURRENT_X, fade.LIGHT_COLOR_TARGET_X, fade.LIGHT_COLOR_TARGET_COLOR_RATE },
    { BLUE[1], ON[1], 8000 }
  )
  local steps = serve(9000, 250)
  T.eq("the first step is near blue, not the On color whole", Select(steps, 1, "sent"), {
    device_on = true,
    brightness = 41,
    hue = 239,
    saturation = 99,
    color_temp = 0,
  })
  --- Whether each step that names a color names where that fade is as it is sent.
  local function onTheFade(commands)
    for _, step in ipairs(commands) do
      local p = math.min(step.at, 8000) / 8000
      local hue, saturation = step.sent.hue, step.sent.saturation
      if
        hue
        and (
          math.abs(hue - (240 + (ON[1] * 360 - 240) * p)) > 1
          or math.abs(saturation - (100 + (ON[2] * 100 - 100) * p)) > 1
        )
      then
        return false
      end
    end
    return true
  end
  T.check("each step's color is where the fade is as it is sent", onTheFade(steps), T.show(each(steps, "hue")))
  T.check("the color moves on with the level", #each(steps, "hue") > 20, #each(steps, "hue"))
  T.eq("the strip ends at 80 % in the On color", { strip.brightness, strip.hue, strip.saturation }, { 80, 152, 40 })
  T.eq("where the proxy is told it", told("LIGHT_COLOR_CHANGED", "at"), { 8000 })

  walked({ brightness = 40 }, NO_POLLS)
  colorTarget(BLUE, 0)
  serve(1000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 41, RATE = 4000 })
  steps = serve(5000, 250)
  T.check("one level over 4 s from blue: the color is walked all the same", #steps > 10, #steps)
  T.eq("to the On color", { strip.brightness, strip.hue, strip.saturation }, { 41, 152, 40 })
  walked({ brightness = 40 }, NO_POLLS)
  colorTarget(BLUE, 0)
  serve(1000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 60000 })
  steps = serve(10000, 250)
  T.eq(
    "over 60 s: a step names the color only once it has moved on from the last sent",
    { #steps, #each(steps, "hue") },
    { 23, 18 }
  )

  walked({ brightness = 40 }, NO_POLLS)
  colorTarget(BLUE, 0)
  serve(1000, 250)
  local asked = now
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 8000 })
  serve(4000, 250)
  local step = held[1]
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop half way tells the color of the step in flight",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] + (ON[1] - BLUE[1]) * ((step.at - asked) / 8000) }
  )
  serve(1000, 250)
  T.eq("which the strip holds", { strip.hue, strip.saturation }, { asks(step).hue, asks(step).saturation })

  -- Dim-To-Warm between two color temperatures: from blue the strip is sent
  -- color temperatures, and reports each as its point.
  forgetSetup()
  proxySetup = setupFile("setup-607.xml")
  walked({ brightness = 40 })
  colorTarget(BLUE, 0)
  serve(1000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 8000 })
  serve(4000, 250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  serve(12000, 250)
  T.eq(
    "a stop there tells the point of the step's color temperature, which the polls after it read",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y"),
    { 0.4 }
  )

  -- Two colors apart, and at 80 % in the Dim-To-Warm color for it.
  forgetSetup()
  proxySetup = ""
  walked({ brightness = 80, hue = 54, saturation = 32 }, NO_POLLS)
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = 60 / 360,
    COLOR_PRESET_COLOR_Y = 0.2,
    COLOR_PRESET_COLOR_MODE = 0,
    COLOR_FADE_PRESET_ID = 2,
    COLOR_FADE_PRESET_ORIGIN = 1,
    COLOR_FADE_PRESET_COLOR_X = 30 / 360,
    COLOR_FADE_PRESET_COLOR_Y = 0.8,
    COLOR_FADE_PRESET_COLOR_MODE = 0,
  })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  steps = serve(3000, 250)
  T.eq("a fade to off with Dim-To-Warm names no color on its way down", each(steps, "hue"), {})
  T.eq("so the strip is off in the color it had", { strip.device_on, strip.hue, strip.saturation }, { false, 54, 32 })
  T.eq("as the proxy is told: no color", told("LIGHT_COLOR_CHANGED"), {})
  forgetSetup()
end

T.section("a level command over a fade that carries a color leaves the color's own steps to run to their end")
do
  -- Blue at 20 %, a scene step to red at 90 % over 10 s, and 5 s in a level
  -- alone: 40 % over 4 s.
  walked({ brightness = 20, hue = 240 }, NO_POLLS)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(90, xy(0, 100), 10000) })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  serve(5000, 250)
  T.eq("half way a step is in flight, on its way up and to red", flying(), {
    { device_on = true, brightness = 54, hue = 124, saturation = 100, color_temp = 0 },
  })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 4000 })
  local steps = serve(6000, 250)
  T.eq(
    "the level turns for 40 % from the step the strip was last sent",
    each(steps, "brightness"),
    { 54, 53, 52, 51, 50, 49, 48, 47, 46, 45, 44, 43, 42, 41, 40 }
  )
  T.eq("and is told 9 s in, at the end of its own ramp", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 9000 })
  T.eq(
    "the hue runs on, a step as the strip answers the one before",
    each(steps, "hue"),
    { 124, 118, 112, 106, 100, 94, 88, 82, 76, 70, 64, 58, 52, 46, 40, 34, 28, 24, 16, 10, 4, 0 }
  )
  T.eq("the color's last step is red, alone", Select(steps, #steps, "sent"), {
    device_on = true,
    hue = 0,
    saturation = 100,
    color_temp = 0,
  })
  T.eq("10 s in, the end of the fade that carried it", told("LIGHT_COLOR_CHANGED", "at"), { 10000 })
  T.eq("where the proxy is told red", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a color a replaced fade carried goes on to its end over the command that replaced it, and is told there")
do
  local ON, DIM = xy(60, 20), xy(30, 80)
  -- 80 %'s Dim-To-Warm color, between DIM and ON.
  local AT80 = { DIM[1] + (ON[1] - DIM[1]) * 0.8, DIM[2] + (ON[2] - DIM[2]) * 0.8 }
  local function onMode(fade)
    proxy("UPDATE_COLOR_ON_MODE", {
      COLOR_PRESET_ID = 1,
      COLOR_PRESET_ORIGIN = 1,
      COLOR_PRESET_COLOR_X = ON[1],
      COLOR_PRESET_COLOR_Y = ON[2],
      COLOR_PRESET_COLOR_MODE = 0,
      COLOR_FADE_PRESET_ID = fade and 2 or 0,
      COLOR_FADE_PRESET_ORIGIN = fade and 1 or 0,
      COLOR_FADE_PRESET_COLOR_X = DIM[1],
      COLOR_FADE_PRESET_COLOR_Y = DIM[2],
      COLOR_FADE_PRESET_COLOR_MODE = 0,
    })
  end
  --- In blue at 40 %, with Dim-To-Warm: a ramp to 80 % over 8 s, 4 s in.
  --- Returns the x of the color the strip was last sent.
  local function halfWay()
    forgetSetup()
    walked({ brightness = 40 }, NO_POLLS)
    onMode(true)
    colorTarget(BLUE, 0)
    serve(1000, 250)
    local asked = now
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 8000 })
    serve(4000, 250)
    return BLUE[1] + (AT80[1] - BLUE[1]) * ((held[1].at - asked) / 8000)
  end
  --- The level and color changes the proxy is told, in order.
  local function ends()
    local out = {}
    for _, s in ipairs(sent) do
      if s.command == "LIGHT_COLOR_CHANGED" or s.command == "LIGHT_BRIGHTNESS_CHANGED" then
        out[#out + 1] = s.command
      end
    end
    return out
  end

  local left = halfWay()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  local fade = told("LIGHT_COLOR_CHANGING")[1] or {}
  T.eq(
    "a fade to off 4 s into it: the proxy is told the color goes on from where it is over the off's 4 s",
    { fade.LIGHT_COLOR_CURRENT_X, fade.LIGHT_COLOR_TARGET_X, fade.LIGHT_COLOR_TARGET_COLOR_RATE },
    { left, AT80[1], 4000 }
  )
  local steps = serve(5000, 250)
  local onTheFade = true
  for _, step in ipairs(steps) do
    local p = math.min(step.at, 4000) / 4000
    if step.at >= 0 and step.sent.hue and math.abs(step.sent.hue - (left + (AT80[1] - left) * p) * 360) > 1 then
      onTheFade = false
    end
  end
  T.check("each step's color is where that fade is as it is sent", onTheFade, T.show(each(steps, "hue")))
  T.check("the color moves on as the level falls", #each(steps, "hue") > 10, #each(steps, "hue"))
  T.eq("the last step is the off, alone", Select(steps, #steps, "sent"), { device_on = false })
  T.eq("so the strip goes off near 80 %'s color", { strip.device_on, strip.hue, strip.saturation }, { false, 58, 33 })
  T.eq("the proxy is told the color at the off's end", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  T.eq("which is 80 %'s", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { AT80[1] })
  T.eq("ahead of the level", ends(), { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" })

  halfWay()
  mark()
  proxy("SET_LEVEL", { LEVEL = 0 })
  T.eq(
    "an off at once: the proxy is told 80 %'s color at once, ahead of the level",
    { ends(), told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X") },
    { { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }, { AT80[1] } }
  )
  steps = serve(3000, 250)
  T.eq("and the strip is sent the off alone, after the step in flight", Select(steps, #steps, "sent"), {
    device_on = false,
  })
  T.eq("nothing follows", #steps, 2)
  serve(300000, 250)
  T.eq("and its poll reads 80 %'s color, held for the next on: nothing more is told", #told("LIGHT_COLOR_CHANGED"), 1)

  halfWay()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  serve(2000, 250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  local x, y =
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")[1], told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y")[1]
  T.eq("a stop 2 s into that off tells one color", #told("LIGHT_COLOR_CHANGED"), 1)
  T.eq("and no step follows the one in flight", #serve(5000, 250), 1)
  T.eq(
    "so the strip holds the color told, on at the level told",
    { strip.hue, strip.saturation, strip.brightness },
    { math.floor((x or 0) * 360 + 0.5), math.floor((y or 0) * 100 + 0.5), levels()[1] }
  )
  halfWay()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  serve(2000, 250)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a color stop there tells one color too", #told("LIGHT_COLOR_CHANGED"), 1)
  steps = serve(3000, 250)
  T.eq("and the steps after name no color: the level goes on to off", {
    #each(steps, "hue"),
    Select(steps, #steps, "sent"),
  }, { 1, { device_on = false } })

  halfWay()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(0, 2000) })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a scene step to off over 2 s: the color goes on over its 2 s",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"),
    { 2000 }
  )
  serve(3000, 250)
  T.eq("and is told at the step's end", told("LIGHT_COLOR_CHANGED", "at"), { 2000 })
  proxy("CLEAR_ALL_SCENES")
  halfWay()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(0, 0) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  steps = serve(3000, 250)
  T.eq("a scene step to off at once: the off, alone, and the strip stays off", {
    Select(steps, #steps, "sent"),
    strip.device_on,
  }, { { device_on = false }, false })
  proxy("CLEAR_ALL_SCENES")

  -- A ramp up from off names each level's own color: none is left to come.
  forgetSetup()
  walked({ device_on = false }, NO_POLLS)
  onMode(true)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 8000 })
  serve(4000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  T.eq(
    "a ramp up from off faded off 4 s in: the proxy is told the color the strip is in, at once",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 0 }
  )
  local named = 0
  for _, step in ipairs(serve(5000, 250)) do
    named = named + ((step.at >= 0 and step.sent.hue) and 1 or 0)
  end
  T.eq("and the steps down name no color", named, 0)

  forgetSetup()
  walked({ device_on = false }, NO_POLLS)
  onMode(false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  serve(1000, 250)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "a level a second into a ramped on: the proxy is told the On color the strip came on in, at once",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )
  T.eq(
    "and the strip is sent the level alone",
    Select(serve(1000, 250), 2, "sent"),
    { device_on = true, brightness = 50 }
  )
  proxy("OFF")
  serve(1000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq(
    "a ramped level a second in: the same, with no color fade told",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGING") },
    { { ON[1] }, {} }
  )
  T.eq("and its steps name no color", #each(serve(3000, 250), "hue"), 0)
  forgetSetup()

  walked({}, NO_POLLS)
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 10,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_FADE_PRESET_ID = 0,
    COLOR_FADE_PRESET_ORIGIN = 0,
  })
  colorTarget(BLUE, 10000)
  serve(2000, 250)
  mark()
  proxy("SET_LEVEL", { LEVEL = 0 })
  T.eq(
    "an off 2 s into a 10 s fade from red to blue: the proxy is told blue ahead of the level",
    { ends(), told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X") },
    { { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }, { BLUE[1] } }
  )
  serve(9000, 250)
  T.eq("and nothing more at the fade's end", #told("LIGHT_COLOR_CHANGED"), 1)
  T.eq("the strip stays off", strip.device_on, false)
  proxy("ON")
  T.eq("with Previous, the next on is in blue", flying(), {
    { device_on = true, brightness = 100, hue = 240, saturation = 100, color_temp = 0 },
  })
  forgetSetup()

  --- With no Color On Mode, the same off, and `on` 2 s after it, while the fade
  --- walks on. Returns where the color fade the proxy is then told goes from and
  --- to, and over how long.
  local function backOn(on)
    forgetSetup()
    walked({}, NO_POLLS)
    colorTarget(BLUE, 10000)
    serve(2000, 250)
    proxy("SET_LEVEL", { LEVEL = 0 })
    serve(2000, 250)
    mark()
    on()
    local fade = told("LIGHT_COLOR_CHANGING")[1] or {}
    return { fade.LIGHT_COLOR_CURRENT_X, fade.LIGHT_COLOR_TARGET_X, fade.LIGHT_COLOR_TARGET_COLOR_RATE }
  end
  local rest = { BLUE[1] * 0.4, BLUE[1], 6000 }
  T.eq(
    "with no Color On Mode, an on 2 s after that off: the proxy is told the fade goes on from where it is over its 6 s left",
    backOn(function()
      proxy("ON")
    end),
    rest
  )
  serve(8000, 250)
  T.eq(
    "and is told blue as the strip gets there",
    { told("LIGHT_COLOR_CHANGED", "at"), colorsTold(), strip.hue },
    { { 6000 }, { BLUE[1] }, 240 }
  )
  T.eq(
    "the same for a ramped on",
    backOn(function()
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
    end),
    rest
  )
  T.eq(
    "and for a scene step to a level alone",
    backOn(function()
      proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(100, 2000) })
      proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
    end),
    rest
  )
  proxy("CLEAR_ALL_SCENES")
  local cyan = xy(180, 100)
  backOn(function()
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(100, cyan, 2000) })
    proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  end)
  T.eq(
    "a scene step on in a color of its own: the proxy is told that color, and no fade",
    { told("LIGHT_COLOR_CHANGING"), colorsTold() },
    { {}, { cyan[1] } }
  )
  proxy("CLEAR_ALL_SCENES")

  halfWay()
  setProperty("Fades", "Light")
  serve(1000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 8000 })
  serve(300, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  T.eq(
    "with Fades on Light, an off in its own fade is one command, and no color fade is told",
    { serve(3000, 250)[1].sent, told("LIGHT_COLOR_CHANGING") },
    { { device_on = false }, {} }
  )
  forgetSetup()
end

T.section("a poll due in a fade goes out between two steps, and one that reads another hand's change ends the fade")
do
  walked({ brightness = 5 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  local steps, polls = serve(9900, 250)
  T.eq("a poll every 5 s: one is answered in the first 9.9 s of a 10 s fade", polls, 1)
  T.eq("which reads the step before it and tells the proxy nothing", sent[2], nil)
  T.eq("the steps go on either side of it", #steps, 38)
  T.eq("never two requests in flight", busiest, 1)
  serve(2000, 250)
  T.eq("and the fade ends on its target", { strip.brightness, levels() }, { 100, { 100 } })

  -- A slow fade leaves the strip free between steps: 5 to 100 % over 5 min.
  walked({ brightness = 5 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300000 })
  serve(9000, 250)
  T.eq("9 s into a 5 min fade the strip is at 8 %", strip.brightness, 8)
  -- The Tapo app, or another controller, sets 70 %.
  strip.brightness = 70
  mark()
  serve(1500, 250)
  T.eq("another hand's 70 %, read by the next poll, is told", levels(), { 70 })
  T.eq("and the strip keeps it: no step follows", { strip.brightness, #serve(20000, 250) }, { 70, 0 })
  T.eq("nor is the proxy told the fade's target at what was its end", #serve(300000, 250) + #levels(), 1)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  T.eq("a fade asked for after it starts from there", each(serve(3000, 250), "brightness")[1], 71)

  --- What the proxy is told of the level, and how many steps follow, when
  --- another hand sets `field` 9 s into a 5 min fade up from 5 %.
  local function otherHand(field, value, connected)
    connected = connected or {}
    connected.brightness = 5
    walked(connected)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300000 })
    serve(9000, 250)
    strip[field] = value
    mark()
    serve(1500, 250)
    return { levels(), #serve(20000, 250) }
  end
  T.eq("switched off by another hand: told, and the fade over", otherHand("device_on", false), { { 0 }, 0 })
  T.eq("put back where the fade began: told all the same", otherHand("brightness", 5), { { 5 }, 0 })
  T.eq("another saturation: the fade is over", otherHand("saturation", 50)[2], 0)
  T.eq("a color temperature: the fade is over", otherHand("color_temp", 3000)[2], 0)
  -- A strip in a color temperature keeps a hue it does not show.
  T.check(
    "a hue read beside a color temperature is no one's change: the fade goes on",
    otherHand("hue", 77, { color_temp = 3000 })[2] > 0
  )

  -- Its color changed by another hand while the driver fades its level.
  walked({ brightness = 5 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300000 })
  serve(9000, 250)
  strip.hue = 120
  mark()
  serve(1500, 250)
  T.eq("a color that is not the driver's ends the fade too", { levels(), strip.brightness }, { { 8 }, 8 })
  T.eq("and is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 120 / 360 })
  T.eq("with no step after", #serve(20000, 250), 0)

  -- A color put back where its fade began.
  walked({})
  colorTarget(BLUE, 300000)
  serve(9700, 250)
  strip.hue = 0
  mark()
  serve(800, 250)
  T.eq("a color put back where its fade began is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0 })
  T.eq("and the fade over", #serve(20000, 250), 0)

  -- The color a ramped on carries, told as changing, when the level is moved.
  forgetSetup()
  walked({ device_on = false })
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = 0,
    COLOR_PRESET_COLOR_Y = 1,
    COLOR_PRESET_COLOR_MODE = 0,
    COLOR_FADE_PRESET_ID = 0,
    COLOR_FADE_PRESET_ORIGIN = 0,
  })
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = BLUE[1], LIGHT_COLOR_TARGET_Y = BLUE[2], LIGHT_COLOR_TARGET_MODE = 0 }
  )
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300000 })
  serve(9000, 250)
  strip.brightness = 70
  mark()
  serve(1500, 250)
  T.eq("another hand in a ramped on: the color it was to end in is told as it reads", {
    levels(),
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
  }, { { 70 }, { 0 } })
  forgetSetup()

  -- What the strip held before a fade was asked for is no part of the fade.
  walked({ brightness = 50 })
  serve(6000, 250)
  strip = info({ brightness = 80, color_temp = 3000 })
  setProperty("IP Address", "192.0.2.25")
  shakeHands()
  reply(info(strip))
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300000 })
  T.eq(
    "what the last strip held is not this one's: its first poll ends no fade",
    each(serve(20000, 250), "brightness"),
    { 81 }
  )

  --- What follows a fade from 50 to 100 % over `rate` ms, asked a second after
  --- another hand set a hue: the colors told in its first 20 s, and its steps.
  local function setBefore(rate)
    walked({ brightness = 50 })
    serve(6000, 250)
    strip.hue = 120
    run(1000)
    mark()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = rate })
    local steps = serve(20000, 250)
    return { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), levels(), each(steps, "brightness") }
  end
  T.eq(
    "a color another hand set before a 5 min fade was asked for is told by the fade's first poll, and ends no fade",
    setBefore(300000),
    { { 120 / 360 }, {}, { 51, 52, 53 } }
  )
  local quick = setBefore(60000)
  T.eq(
    "nor one of 1 min, whose first steps go out before that poll",
    { quick[1], quick[2], quick[3][1], quick[3][#quick[3]] },
    { { 120 / 360 }, {}, 51, 66 }
  )

  -- A scene's fade that another hand ends takes the scene's later steps with it.
  walked({ brightness = 20 })
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(80, 600000) .. levelStep(10, 2000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  serve(9000, 250)
  strip.brightness = 30
  mark()
  serve(2000, 250)
  T.eq("another hand's 30 % in a scene's first step is told", levels(), { 30 })
  T.eq(
    "and the scene is over: its next step, due at the first's end, sends nothing",
    { #serve(600000, 250), strip.brightness, levels() },
    { 0, 30, { 30 } }
  )
  proxy("CLEAR_ALL_SCENES")

  -- The strip's own report of what it was sent is no news in a color fade.
  walked({})
  colorTarget(BLUE, 300000)
  serve(21000, 250)
  T.eq("four polls into a 5 min color fade the proxy has been told no color", told("LIGHT_COLOR_CHANGED", "at"), {})
  T.check("and the steps go on", strip.hue > 10, strip.hue)
end

T.section("a fade ends where it is when the strip stops answering or the backend is started again, and is told as read")
do
  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  serve(2000, 250)
  mark()
  fail("Klap: request timed out")
  T.eq("a step the strip never answers: no step follows", #serve(20000, 250), 0)
  serve(300000, 250)
  T.eq("and the strip is told at the step before it once it is read", levels(), { 0, 20 })

  -- A Reconnect 2 s into a 4 s fade, and the strip found again at 8 s.
  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  serve(2050, 250)
  mark()
  EC.Reconnect()
  run(6000)
  T.eq("a Reconnect that outlasts the fade: nothing is told at its end, the target never sent", sent, {})
  shakeHands()
  local steps = serve(8000, 250)
  T.eq("the strip found again is told at the step it was last sent", levels(), { 49 })
  T.eq("and is sent no step after that one", each(steps, "brightness"), { 49 })

  walked({}, NO_POLLS)
  colorTarget(BLUE, 4000)
  serve(2050, 250)
  mark()
  setProperty("Protocol", "KLAP")
  run(6000)
  T.eq("a color's fade that a change of Protocol outlasts: nothing is told at its end", sent, {})
  shakeHands()
  serve(8000, 250)
  T.check(
    "the strip is told in the color it was last sent",
    #colorsTold() == 1 and math.abs(colorsTold()[1] - 111 / 360) < 1e-3,
    T.show(colorsTold())
  )
  setProperty("Protocol", "Auto")

  walked({ brightness = 20 }, NO_POLLS)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(80, BLUE, 4000) .. levelStep(10, 2000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  serve(2050, 250)
  mark()
  EC.Reconnect()
  run(6000)
  T.eq("a scene's step that a Reconnect outlasts: nothing told at its end, and its next step sends nothing", {
    sent,
    flying(),
  }, { {}, { { device_on = true, brightness = 48, hue = 111, saturation = 100, color_temp = 0 } } })
  shakeHands()
  serve(8000, 250)
  T.eq("the strip found again is told at that step, and the scene is over", { levels(), #serve(8000, 250) }, {
    { 48 },
    0,
  })
  proxy("CLEAR_ALL_SCENES")

  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  serve(2050, 250)
  mark()
  EC.Reconnect()
  run(300)
  shakeHands()
  steps = serve(12000, 250)
  T.eq("a Reconnect the strip answers at once: the fade is not taken up again", {
    each(steps, "brightness"),
    levels(),
  }, { { 23 }, { 23 } })
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

local DRIVERS = {
  has_fixed_ramp_rate = false,
  fixed_ramp_rate = 0,
  brightness_rate_min = 0,
  brightness_rate_max = 65535,
  color_rate_behavior = 1,
  color_rate_min = 0,
  color_rate_max = 65535,
  supports_brightness_stop = true,
  supports_color_stop = true,
}

--- The same for a light that fades by itself, `ms` between two states.
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
  T.eq("with the capabilities of a light whose fades take a rate, and stop", rates(), DRIVERS)
  startDriver({ ["Protocol"] = "Legacy" })
  reply(sysinfo())
  T.eq("a Kasa bulb on the IOT schema: hidden", hidden["Fades"], true)
  T.eq("with the capabilities it had", rates(), DRIVERS)
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
  T.eq("and the next on carries the color", Select(flying(), 1, "hue"), 240)

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

T.section("with Fades on Light a stop sends nothing, and a held button goes to its end")
do
  walked({ brightness = 30 }, NO_POLLS)
  setProperty("Fades", "Light")
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 5000 })
  serve(300, 250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  proxy("SET_COLOR_STOP")
  T.eq("a stop 0.3 s into a level's fade: nothing is sent, and nothing told", { flying(), sent }, { {}, {} })
  serve(2000, 250)
  T.eq("the level is told at the fade's end, where the strip has gone", levels(), { 90 })
  colorTarget(BLUE, 5000)
  serve(300, 250)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a stop 0.3 s into a color's fade: nothing is sent, and nothing told", { flying(), sent }, { {}, {} })
  T.eq("nor at the fade's end, where the strip has gone", serve(2000, 250), {})
  T.eq("the color is told at the fade's end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })

  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  T.eq("Top held: one command, for full", flying(), { { device_on = true, brightness = 100 } })
  serve(300, 250)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE })
  T.eq("its release sends nothing", flying(), {})
  serve(2000, 250)
  T.eq("and the strip is told at full, where it went", { strip.brightness, levels() }, { 100, { 100 } })

  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 5000 })
  serve(300, 250)
  EC.Reconnect()
  run(6000)
  T.eq(
    "a Reconnect in the strip's own fade: the level it was sent is told at the fade's end",
    { levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 40 }, { 1000 } }
  )
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
  T.eq("with no fixed rate told until they are", rates().has_fixed_ramp_rate, false)
  serve(1000, 250)
  -- The strip is away when Driver is chosen.
  run(9000)
  fail("Klap: request timed out")
  mark()
  setProperty("Fades", "Driver")
  T.eq("Driver chosen while the strip is away: the proxy is told nothing of rates yet", rates(), {})
  run(10000)
  reply(info())
  T.eq("and the driver's with the strip's capabilities when it is back", rates(), DRIVERS)

  walked({}, NO_POLLS)
  run(4000)
  T.eq("a strip that connects with Fades on Driver is asked nothing of its fades", flying(), {})
  setProperty("Fades", "Light")
  serve(1000, 250)
  mark()
  setProperty("Fades", "Driver")
  T.eq("choosing Driver again writes the strip nothing: its fades stay as they are", flying(), {})
  T.eq("and the proxy is told rates and stops are the driver's", rates(), DRIVERS)

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

T.section("changing Fades while a ramp runs ends the ramp at its target")
do
  walked({ brightness = 5 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  serve(4000, 250)
  mark()
  setProperty("Fades", "Light")
  T.eq("Driver to Light 4 s into a 10 s fade: the proxy is told the target at once", levels(), { 100 })
  local after = serve(3000, 250)
  T.eq("the strip is sent it behind the step in flight, and no step after", each(after, "brightness"), { 42, 100 })
  T.eq("and nothing is told at what was the fade's end", #serve(8000, 250) + #levels(), 1)

  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 5000 })
  serve(300, 250)
  mark()
  setProperty("Fades", "Driver")
  T.eq("Light to Driver 0.3 s into the strip's own fade: the proxy is told the target at once", levels(), { 20 })
  T.eq("and the strip, on its way there, is sent nothing", serve(3000, 250), {})

  -- A color fading too.
  walked({ brightness = 20 }, NO_POLLS)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(80, BLUE, 8000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  serve(4000, 250)
  mark()
  setProperty("Fades", "Light")
  T.eq("with a color fading too: both are told at their targets", {
    levels(),
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
  }, { { 80 }, { tonumber(tostring(BLUE[1])) } })
  serve(3000, 250)
  T.eq("and the strip ends on both", { strip.brightness, strip.hue }, { 80, 240 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a rated on from off is lit by its first step, and told to the proxy as a change from 1")
do
  -- The proxy takes LIGHT_STATE from CHANGING's current level: from 0 it showed the light off until CHANGED.
  --- What the proxy is told of the level since the mark: { "CHANGING", from, to } and { "CHANGED", level }.
  local function changes()
    local out = {}
    for _, s in ipairs(sent) do
      local p = s.params
      if s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGING" then
        out[#out + 1] = { "CHANGING", p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET }
      elseif s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGED" then
        out[#out + 1] = { "CHANGED", p.LIGHT_BRIGHTNESS_CURRENT }
      end
    end
    return out
  end
  local TOGGLE, CLICK = 2, 2
  forgetSetup()
  local ons = {
    { "Set Brightness Target", "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 } },
    { "Ramp Scene Up", "RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 2000 } },
    { "a scene step over 2 s", "ACTIVATE_SCENE", { SCENE_ID = 7 } },
    { "a Top click", "BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = CLICK } },
    { "a Toggle hold", "BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS } },
  }
  for _, c in ipairs(ons) do
    walked({ device_on = false }, NO_POLLS)
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(60, 2000) })
    mark()
    proxy(c[2], c[3])
    serve(10000, 250)
    local to = told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET")[1]
    T.eq(c[1] .. " from off: one CHANGING from 1, then one CHANGED", changes(), {
      { "CHANGING", 1, to },
      { "CHANGED", to },
    })
    proxy("CLEAR_ALL_SCENES")
  end
  -- A slow on to a low level, whose line takes 1.5 s to reach half a level.
  walked({ device_on = false }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 10, RATE = 30000 })
  run(100)
  T.eq("10 % over 30 s from off: the fade's first step lights the strip, at 1 %", flying(), {
    { device_on = true, brightness = 1 },
  })

  -- A strip that fades by itself, and a Kasa bulb, are lit by the on itself.
  walked({ device_on = false }, NO_POLLS)
  setProperty("Fades", "Light")
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  T.eq("with Fades on Light: the on goes at once", flying(), { { device_on = true, brightness = 60 } })
  serve(3000, 250)
  T.eq("and is told from 1", changes(), { { "CHANGING", 1, 60 }, { "CHANGED", 60 } })
  bulb({ on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  reply()
  run(3000)
  T.eq("a Kasa bulb, which fades up from the on: told from 1", changes(), { { "CHANGING", 1, 50 }, { "CHANGED", 50 } })

  -- A fade to off, and a rated level for a light that is on, are told from where it is, as before.
  for _, to in ipairs({ 30, 0 }) do
    walked({ brightness = 60 }, NO_POLLS)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = to, RATE = 2000 })
    serve(3000, 250)
    T.eq("a rated level to " .. to .. " from 60: from 60", changes(), { { "CHANGING", 60, to }, { "CHANGED", to } })
  end
end

T.section("Get Light Level in a ramp tells the proxy where the ramp has got to, not a level the light stopped at")
do
  -- Light V2 takes a CHANGED level as where the brightness stopped: in an on from off, a CHANGED 0 shows it off.
  --- What the proxy is told of the level since the mark: { "CHANGING", from, to, ms } and { "CHANGED", level }.
  local function changes()
    local out = {}
    for _, s in ipairs(sent) do
      local p = s.params
      if s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGING" then
        out[#out + 1] = { "CHANGING", p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET, p.RATE }
      elseif s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGED" then
        out[#out + 1] = { "CHANGED", p.LIGHT_BRIGHTNESS_CURRENT }
      end
    end
    return out
  end
  --- What the proxy is told to a Get Light Level.
  local function getLevel()
    mark()
    proxy("GET_LIGHT_LEVEL")
    return changes()
  end

  -- A Kasa bulb, which fades by the time a command carries.
  startDriver({ ["Protocol"] = "Legacy", ["Poll Rate (Seconds)"] = "300" })
  reply(sysinfo({ brightness = 20 }))
  T.eq("a Kasa bulb at rest: the level it is at", getLevel(), { { "CHANGED", 20 } })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  reply()
  run(2000)
  T.eq("half way from 20 to 100 % over 4 s: a ramp from 60, 2 s left", getLevel(), { { "CHANGING", 60, 100, 2000 } })
  T.eq("and the bulb is sent nothing for it", flying(), {})
  mark()
  run(2500)
  T.eq("the ramp's end is told as before", changes(), { { "CHANGED", 100 } })
  T.eq("and at rest it is the level the ramp stopped at", getLevel(), { { "CHANGED", 100 } })
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(60, 2000) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  reply()
  run(500)
  T.eq("a scene step's ramp, a quarter of the way: from 90, 1.5 s left", getLevel(), { { "CHANGING", 90, 60, 1500 } })
  proxy("CLEAR_ALL_SCENES")

  bulb({ on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  reply()
  T.eq("an on from off over 6 s, as it begins: a ramp from 1", getLevel(), { { "CHANGING", 1, 60, 6000 } })
  run(3000)
  T.eq("half way: from 30, and no CHANGED 0", getLevel(), { { "CHANGING", 30, 60, 3000 } })

  bulb({ brightness = 60 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  reply()
  run(1000)
  T.eq("half way through a fade to off from 60 %: from 30, 1 s left", getLevel(), { { "CHANGING", 30, 0, 1000 } })

  -- A light on an outlet fades by a command's time too.
  C4:Bind(900, 1, C4:GetDeviceID(), 1, "TPLINK_LIGHT")
  startDriver()
  RFP.UPDATE_STATE(1, "UPDATE_STATE", {
    entity = SerializeSafe({ supported_color_modes = { require("constants").LightColorMode.COLOR_MODE_BRIGHTNESS } }),
    state = SerializeSafe({ state = true, brightness = 0.2 }),
  })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(2000)
  T.eq("a light on an outlet, half way: from 60, 2 s left", getLevel(), { { "CHANGING", 60, 100, 2000 } })
  C4:Unbind(C4:GetDeviceID(), 1)

  -- A strip the driver walks is where its last step put it, behind the line.
  walked({ brightness = 20 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  serve(2000, 250)
  T.eq("a strip the driver walks, half way: its step in flight", flying(), { { device_on = true, brightness = 57 } })
  T.eq("the ramp is from that step, at 57 %, 2 s left", getLevel(), { { "CHANGING", 57, 100, 2000 } })
  serve(3000, 250)
  T.eq("at rest it is the level the walk ended at", getLevel(), { { "CHANGED", 100 } })

  -- A strip that fades by itself takes a second between two states.
  walked({ brightness = 20 }, NO_POLLS)
  setProperty("Fades", "Light")
  serve(1000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 6000 })
  serve(500, 250)
  T.eq("with Fades on Light, half way through its own fade: from 60, 500 ms left", getLevel(), {
    { "CHANGING", 60, 100, 500 },
  })
end

T.section("the button LEDs follow the light being on: from the start of a ramp up, to the end of a fade to off")
do
  local TOP_LINK, TOGGLE_LINK, BOTTOM_LINK = 300, 301, 302
  --- What the Top Button Link's LED is told since the mark: { ms, STATE }.
  local function leds()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == TOP_LINK and s.command == "MATCH_LED_STATE" then
        out[#out + 1] = { s.at, s.params.STATE }
      end
    end
    return out
  end
  --- What Request Button Colors tells the Top, Toggle and Bottom LEDs.
  local function buttonColors()
    local from, out = #sent, {}
    proxy("REQUEST_BUTTON_COLORS")
    for i = from + 1, #sent do
      if sent[i].command == "MATCH_LED_STATE" then
        out[sent[i].binding] = sent[i].params.STATE
      end
    end
    return { out[TOP_LINK], out[TOGGLE_LINK], out[BOTTOM_LINK] }
  end
  local TOGGLE, CLICK = 2, 2
  forgetSetup()
  local ons = {
    { "Set Brightness Target", "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 } },
    { "Ramp Scene Up", "RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 2000 } },
    { "a scene step over 2 s", "ACTIVATE_SCENE", { SCENE_ID = 7 } },
    { "a Top click", "BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = CLICK } },
    { "a Toggle hold", "BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS } },
  }
  for _, c in ipairs(ons) do
    walked({ device_on = false }, NO_POLLS)
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(60, 2000) })
    mark()
    proxy(c[2], c[3])
    local rate = told("LIGHT_BRIGHTNESS_CHANGING", "RATE")[1]
    serve(rate / 2, 250)
    T.eq(c[1] .. " from off: the LEDs are told on as its ramp begins", leds(), { { 0, true } })
    T.eq("and Request Button Colors half way says on", buttonColors(), { true, true, false })
    mark()
    serve(rate, 250)
    T.eq("and the LEDs are told nothing more at its end", leds(), {})
    proxy("CLEAR_ALL_SCENES")
  end

  -- A Kasa bulb, and a strip that fades by itself.
  bulb({ on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  reply()
  run(3000)
  T.eq("a Kasa bulb ramped on from off: on as its ramp begins", leds(), { { 0, true } })
  walked({ device_on = false }, NO_POLLS)
  setProperty("Fades", "Light")
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  serve(3000, 250)
  T.eq("with Fades on Light: on as its own fade begins", leds(), { { 0, true } })

  -- A fade to off is on until its end, as before, and a ramp between two lit levels is no change.
  walked({ brightness = 60 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  serve(1000, 250)
  T.eq("a fade to off: the LEDs are told nothing half way", leds(), {})
  T.eq("and Request Button Colors half way says on", buttonColors(), { true, true, false })
  mark()
  serve(2000, 250)
  T.eq("they are told off at the fade's end", leds(), { { 1000, false } })
  walked({ brightness = 60 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  serve(3000, 250)
  T.eq("a rated level from 60 to 30 %: the LEDs are told nothing", leds(), {})
end

T.section("a ramp up from off ended at off leaves Previous On where it was, or at the level the light reached")
do
  -- The proxy writes Previous On at an off from the last level it was told: in a ramp from off, the CHANGING's 1.
  --- What the proxy is told of the level since the mark: { "CHANGING", from, to } and { "CHANGED", level }.
  local function changes()
    local out = {}
    for _, s in ipairs(sent) do
      local p = s.params
      if s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGING" then
        out[#out + 1] = { "CHANGING", p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET }
      elseif s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGED" then
        out[#out + 1] = { "CHANGED", p.LIGHT_BRIGHTNESS_CURRENT }
      end
    end
    return out
  end
  --- Previous On, from `level`, after what the proxy was told since the mark, by its rule on OS 4.3.0: a level
  --- of 1 or more, a CHANGED's or a CHANGING's current, is the light on, and the off after it writes the last.
  local function previousOn(level)
    local on, last = false, nil
    for _, c in ipairs(changes()) do
      if c[2] >= 1 then
        on, last = true, c[2]
      elseif on then
        on, level = false, last
      end
    end
    return level
  end
  local OFF = { on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } }
  local ON = { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 }
  local TOGGLE_LINK = 301
  -- The proxy's setup has Previous On at 20 %.
  forgetSetup()
  proxySetup = setupFile("setup-607.xml")

  --- Each light, off: whether it takes a stop, and how it is started.
  local backends = {
    {
      "a Kasa bulb",
      true,
      function()
        bulb(OFF)
      end,
    },
    {
      "a light on an outlet",
      true,
      function()
        C4:Bind(900, 1, C4:GetDeviceID(), 1, "TPLINK_LIGHT")
        startDriver()
        RFP.UPDATE_STATE(1, "UPDATE_STATE", {
          entity = SerializeSafe({
            supported_color_modes = { require("constants").LightColorMode.COLOR_MODE_BRIGHTNESS },
          }),
          state = SerializeSafe({ state = false }),
        })
        mark()
      end,
    },
    {
      "a strip the driver walks",
      true,
      function()
        -- Reached directly, not through the outlet.
        C4:Unbind(C4:GetDeviceID(), 1)
        walked({ device_on = false }, NO_POLLS)
      end,
    },
    {
      "a strip with Fades on Light",
      false,
      function()
        walked({ device_on = false }, NO_POLLS)
        setProperty("Fades", "Light")
        serve(1000, 250)
        mark()
      end,
    },
  }
  local ends = {
    { "a Set Brightness Stop", "SET_BRIGHTNESS_STOP" },
    { "an off at once", "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 } },
    { "a fade to off", "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 } },
  }
  -- 5 ms in, a line from off has not reached half a level, nor has a strip the driver walks been sent its first step.
  for _, b in ipairs(backends) do
    for _, e in ipairs(ends) do
      if b[2] or e[2] ~= "SET_BRIGHTNESS_STOP" then
        b[3]()
        proxy("SET_BRIGHTNESS_TARGET", ON)
        run(5)
        proxy(e[2], e[3])
        T.eq(b[1] .. ", " .. e[1] .. " 5 ms into an on from off: the level to keep is told before the off", changes(), {
          { "CHANGING", 1, 60 },
          { "CHANGING", 20, 0 },
          { "CHANGED", 0 },
        })
        T.eq("so Previous On stays at 20", previousOn(20), 20)
      end
    end
  end

  -- A held button released, a scene ramp stopped, and a stop after Get Light Level, before the bulb is lit.
  bulb(OFF)
  proxy("SET_HOLD_RATE_UP", { RATE = 5000 })
  mark()
  RFP.DO_PUSH(TOGGLE_LINK, "DO_PUSH", {})
  run(20)
  RFP.DO_RELEASE(TOGGLE_LINK, "DO_RELEASE", {})
  T.eq("a Toggle Button Link held from off and released 20 ms in", changes(), {
    { "CHANGING", 1, 100 },
    { "CHANGING", 20, 0 },
    { "CHANGED", 0 },
  })
  bulb(OFF)
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 5000 })
  run(20)
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq("Ramp Scene Up stopped 20 ms in", previousOn(20), 20)
  bulb(OFF)
  proxy("SET_BRIGHTNESS_TARGET", ON)
  run(10)
  proxy("GET_LIGHT_LEVEL")
  run(10)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop after Get Light Level, both before the bulb is lit", changes(), {
    { "CHANGING", 1, 60 },
    { "CHANGING", 1, 60 },
    { "CHANGING", 20, 0 },
    { "CHANGED", 0 },
  })

  -- An off at once after the light is lit keeps the level it reached.
  bulb(OFF)
  proxy("SET_BRIGHTNESS_TARGET", ON)
  run(3000)
  proxy("OFF")
  T.eq("a Kasa bulb turned off 3 s into the on: from 30, where its line is", changes(), {
    { "CHANGING", 1, 60 },
    { "CHANGING", 30, 0 },
    { "CHANGED", 0 },
  })
  T.eq("so Previous On is 30", previousOn(20), 30)
  walked({ device_on = false }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", ON)
  serve(3000, 250)
  T.eq("a strip the driver walks, 3 s in: its step in flight", flying(), { { device_on = true, brightness = 29 } })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 })
  T.eq("turned off then, Previous On is that step", previousOn(20), 29)
  walked({ device_on = false }, NO_POLLS)
  setProperty("Fades", "Light")
  serve(1000, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", ON)
  serve(500, 250)
  proxy("OFF")
  serve(2000, 250)
  T.eq("a strip with Fades on Light, half way through its own fade on: a fade to off from 30, as before", changes(), {
    { "CHANGING", 1, 60 },
    { "CHANGING", 30, 0 },
    { "CHANGED", 0 },
  })

  -- Previous On as the proxy sends it, and none known.
  forgetSetup()
  proxySetup = ""
  bulb(OFF)
  proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = 35 })
  proxy("SET_BRIGHTNESS_TARGET", ON)
  run(5)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("Previous On at 35 as the proxy sent it: 35 is kept", previousOn(35), 35)
  forgetSetup()
  bulb(OFF)
  proxy("SET_BRIGHTNESS_TARGET", ON)
  run(5)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("with no Previous On known, the off alone, as before", changes(), { { "CHANGING", 1, 60 }, { "CHANGED", 0 } })

  -- An on that ends, and then an off or a fade to off, are told as before.
  for _, off in ipairs({ { "an off at once", 0 }, { "a fade to off", 2000 } }) do
    bulb(OFF)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 1000 })
    reply()
    run(1500)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = off[2] })
    reply()
    run(3000)
    local want = { { "CHANGING", 1, 60 }, { "CHANGED", 60 } }
    if off[2] > 0 then
      want[#want + 1] = { "CHANGING", 60, 0 }
    end
    want[#want + 1] = { "CHANGED", 0 }
    T.eq("a rated on to 60 that ended, then " .. off[1], changes(), want)
    T.eq("so Previous On is 60", previousOn(20), 60)
  end
end

T.section("what a Kasa bulb and a light on an outlet are sent, and the proxy told, is as it was")
do
  local GREEN = xy(120, 50)
  local BOTTOM, CLICK = 1, 2

  --- A table as text, its keys in order.
  local function dump(value)
    if type(value) ~= "table" then
      return tostring(value)
    end
    local keys, parts = {}, {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for i, key in ipairs(keys) do
      parts[i] = tostring(key) .. "=" .. dump(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  --- An evening's commands: levels, ramps and their stops, a held button, a
  --- click, colors and a scene. `pass(ms)` lets the time between them pass.
  local function evening(pass)
    proxy("SET_HOLD_RATE_UP", { RATE = 3000 })
    proxy("SET_CLICK_RATE_DOWN", { RATE = 750 })
    proxy("SET_LEVEL", { LEVEL = 40 })
    pass(1000)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 4000 })
    pass(2000)
    proxy("SET_BRIGHTNESS_STOP")
    pass(1000)
    proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
    pass(1500)
    proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE })
    pass(1000)
    colorTarget(BLUE, 3000)
    pass(1000)
    proxy("SET_COLOR_STOP")
    pass(1000)
    colorTarget(GREEN, 2000)
    pass(3000)
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(20, BLUE, 3000) .. levelStep(70, 2000) })
    proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
    pass(6000)
    proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
    pass(110)
    proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = CLICK })
    pass(2000)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
    pass(3000)
    proxy("RAMP_TO_LEVEL", { LEVEL = 10, TIME = 1500 })
    pass(2000)
    proxy("OFF")
    pass(1000)
    proxy("CLEAR_ALL_SCENES")
  end

  --- What the driver sent and told since the mark, a line each: the ms, the
  --- binding and the command with its params, an outlet's command opened.
  local function transcript(requests)
    local lines = {}
    for _, s in ipairs(sent) do
      local params = s.command == "ENTITY_COMMAND" and DeserializeSafe(s.params.body) or s.params
      lines[#lines + 1] = { s.at, ("%6d %4d %s %s"):format(s.at, s.binding, s.command, dump(params)) }
    end
    for _, request in ipairs(requests or {}) do
      lines[#lines + 1] = { request.at, ("%6d  req %s"):format(request.at, dump(request.payload)) }
    end
    -- By time, and as made within one ms: the sort keeps no order of its own.
    for i, line in ipairs(lines) do
      line[3] = i
    end
    table.sort(lines, function(a, b)
      return a[1] < b[1] or (a[1] == b[1] and a[3] < b[3])
    end)
    for i, line in ipairs(lines) do
      lines[i] = line[2]
    end
    return table.concat(lines, "\n") .. "\n"
  end

  --- The transcript recorded on the commit before, and the first line of
  --- `got` that is not its line.
  local function recorded(name, got)
    local f = assert(io.open(HERE .. "/light_sent/" .. name, "rb"))
    local want = f:read("*a")
    f:close()
    local wanted = want:gmatch("[^\n]*")
    for line in got:gmatch("[^\n]*") do
      local was = wanted()
      if line ~= was then
        return want, ("got %q, want %q"):format(line, tostring(was))
      end
    end
    return want
  end

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

  -- A Kasa bulb that answers each request 200 ms after it is made.
  forgetSetup()
  bulb()
  local bulbState = { on_off = 1, brightness = 100, hue = 0, saturation = 100, color_temp = 0 }
  local requests, seen = {}, {}
  evening(function(ms)
    local stop = now + ms
    while now < stop do
      for _, request in ipairs(held) do
        if not seen[request] then
          seen[request] = true
          requests[#requests + 1] = { at = request.at - start, payload = request.payload }
        end
      end
      local request = held[1]
      if request == nil or now - request.at < 200 then
        advance(stop, request and request.at + 200)
      elseif asks(request) == "poll" then
        local on = bulbState.on_off == 1
        reply(sysinfo(on and bulbState or { on_off = 0, dft_on_state = bulbState }))
      else
        for field, value in pairs(asks(request)) do
          bulbState[field] = value
        end
        reply()
      end
    end
  end)
  local got = transcript(requests)
  local want, difference = recorded("kasa-bulb.txt", got)
  T.check("a Kasa bulb on the IOT schema: every request and every notify", got == want, difference)

  -- A light bound to a TP-Link Outlet output: one that dims and takes a color,
  -- which pins the light code, and one that only switches, as an outlet does.
  local Mode = require("constants").LightColorMode
  for name, modes in pairs({
    ["outlet-color.txt"] = { Mode.COLOR_MODE_RGB_COLOR_TEMPERATURE },
    ["outlet-switch.txt"] = { Mode.COLOR_MODE_ON_OFF },
  }) do
    C4:Bind(900, 1, C4:GetDeviceID(), 1, "TPLINK_LIGHT")
    startDriver()
    RFP.UPDATE_STATE(1, "UPDATE_STATE", {
      entity = SerializeSafe({ supported_color_modes = modes, min_mireds = 153, max_mireds = 400 }),
      state = SerializeSafe({
        state = true,
        brightness = 1.0,
        color_mode = Mode.COLOR_MODE_RGB,
        red = 1,
        green = 0,
        blue = 0,
      }),
    })
    mark()
    evening(run)
    got = transcript()
    want, difference = recorded(name, got)
    T.check("a light on an outlet, " .. name .. ": every command and every notify", got == want, difference)
    C4:Unbind(C4:GetDeviceID(), 1)
  end
end

--- Set a light's Min and Max On Level, as Composer does.
local function onLevels(min, max)
  proxy("SET_MIN_ON_LEVEL", { LEVEL = min })
  proxy("SET_MAX_ON_LEVEL", { LEVEL = max })
end

--- Forget the range: the store outlives a reload, and the next light has none.
local function noRange()
  persist:delete("min_on_level")
  persist:delete("max_on_level")
end

T.section("Max and Min On Level: each level goes out between the two, and each report reads back through them")
do
  local BOTTOM, CLICK = 1, 2
  forgetSetup()
  noRange()
  bulb()
  onLevels(20, 80)
  T.eq("a range set on a Kasa bulb at full sends it nothing", flying(), {})
  T.eq("and tells nothing: full reads as level 100", levels(), {})
  T.eq("the range is echoed", { told("MIN_ON"), told("MAX_ON") }, { { "20" }, { "80" } })
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("level 100 goes out at the Max, from full, which reads as 100", answered(), {
    on_off = 1,
    brightness = 80,
    ignore_default = 1,
  })
  proxy("SET_LEVEL", { LEVEL = 1 })
  T.eq("level 1 at the Min", answered(), { on_off = 1, brightness = 20, ignore_default = 1 })
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "level 50 at the whole percent nearest its place",
    answered(),
    { on_off = 1, brightness = 50, ignore_default = 1 }
  )
  T.eq("the proxy is told each level asked for", levels(), { 100, 1, 50 })

  mark()
  run(5000)
  reply(sysinfo({ brightness = 50 }))
  T.eq("a poll of the 50 % level 50 went out at tells nothing, though 50 % reads as 51", levels(), {})
  run(5000)
  reply(sysinfo({ brightness = 80 }))
  T.eq("80 % set in the Kasa app reads as level 100", levels(), { 100 })
  run(5000)
  reply(sysinfo({ brightness = 10 }))
  T.eq("and 10 %, under the Min, as level 1", levels(), { 100, 1 })
  proxy("SET_LEVEL", { LEVEL = 1 })
  T.eq("so level 1 goes out, and puts the bulb at the Min", answered(), {
    on_off = 1,
    brightness = 20,
    ignore_default = 1,
  })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  T.eq("a rated level goes out at its place too", answered(), {
    on_off = 1,
    brightness = 80,
    ignore_default = 1,
    transition_period = 2000,
  })
  run(2000)

  -- From full under a new Max a light is outside the range: a level command, a scene step and a held button
  -- ramp from there.
  noRange()
  bulb()
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  T.eq("level 100 over 2 s from full under a Max of 80 goes out over its rate", answered(), {
    on_off = 1,
    brightness = 80,
    ignore_default = 1,
    transition_period = 2000,
  })
  run(3000)
  noRange()
  bulb()
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(100, 2000) })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("a scene step to level 100 over 2 s from full under a Max of 80 goes out", answered(), {
    on_off = 1,
    brightness = 80,
    ignore_default = 1,
    transition_period = 2000,
  })
  T.eq("and is told as a ramp from 100 to 100", told("LIGHT_BRIGHTNESS_CHANGING"), {
    { LIGHT_BRIGHTNESS_CURRENT = 100, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 },
  })
  run(3000)
  proxy("CLEAR_ALL_SCENES")
  noRange()
  bulb()
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  proxy("SET_HOLD_RATE_DOWN", { RATE = 4000 })
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  reply()
  run(1000)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE })
  T.eq("Bottom held from full under the same Max, let go a quarter of the way: the bulb holds at 75 %", answered(), {
    on_off = 1,
    brightness = 75,
    ignore_default = 1,
  })
  T.eq("which is level 94 on 1 to 80", levels(), { 94 })
  bulb()
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  reply()
  run(200)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE })
  T.eq("let go 200 ms in, still above the Max: the bulb holds at 95 %, shown at 100", { answered(), levels() }, {
    { on_off = 1, brightness = 95, ignore_default = 1 },
    { 100 },
  })
  bulb()
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  proxy("SET_CLICK_RATE_DOWN", { RATE = 2000 })
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  reply()
  run(110)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = CLICK })
  reply()
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a Bottom click from there fades from full, as its press found it: half way it is at 50 %", answered(), {
    on_off = 1,
    brightness = 50,
    ignore_default = 1,
  })

  -- A Min On Level of 0 is level 1 at 1 %, the least a light that is on takes.
  noRange()
  bulb()
  proxy("SET_MIN_ON_LEVEL", { LEVEL = 0 })
  proxy("SET_LEVEL", { LEVEL = 1 })
  T.eq("with a Min On Level of 0, level 1 is 1 %", answered(), { on_off = 1, brightness = 1, ignore_default = 1 })

  -- A Min at the Max puts every on level at the one brightness, which reads back as any of them.
  noRange()
  bulb()
  onLevels(50, 50)
  mark()
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("with Min and Max On Level both 50, level 100 takes a bulb at full to 50 %", answered(), {
    on_off = 1,
    brightness = 50,
    ignore_default = 1,
  })
  proxy("SET_LEVEL", { LEVEL = 30 })
  T.eq("and level 30 is 50 % too, sent again", answered(), { on_off = 1, brightness = 50, ignore_default = 1 })
  run(5000)
  reply(sysinfo({ brightness = 50 }))
  T.eq("a poll of 50 % then tells nothing more", levels(), { 100, 30 })

  -- A strip, the driver's own walk and its own fades alike.
  noRange()
  walked({ brightness = 50 }, NO_POLLS)
  onLevels(20, 80)
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("a strip is sent level 100 at the Max", answered(), { device_on = true, brightness = 80 })
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(1, 0) })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("and a scene step's level 1 at the Min", answered(), { device_on = true, brightness = 20 })
  setProperty("Fades", "Light")
  serve(1000, 250)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 3000 })
  T.eq("with Fades on Light a rated level goes out once, at its place", flying(), {
    { device_on = true, brightness = 50 },
  })
  serve(3000, 250)
  noRange()
end

T.section("a new Max or Min On Level leaves the light where it is, and shows it at its level on the new range")
do
  forgetSetup()
  noRange()
  bulb({ brightness = 50 })
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  T.eq("a Max of 80 set on a bulb at 50 % sends it nothing", flying(), {})
  T.eq("and shows it at 62, its level on 1 to 80", levels(), { 62 })
  mark()
  proxy("SET_LEVEL", { LEVEL = 62 })
  T.eq("a Set Level to the level shown sends nothing", flying(), {})
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 100 })
  T.eq("and with the Max back at 100 it is shown at 50 again", levels(), { 62, 50 })

  -- A ramp in flight runs on between the brightnesses it was sent between.
  noRange()
  bulb({ brightness = 20 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  reply()
  run(1000)
  mark()
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  T.eq("a Max of 80 set a quarter of the way up from 20 to 100 % sends nothing", { flying(), levels() }, { {}, {} })
  run(1000)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop half way holds the bulb where it is, at 60 %", answered(), {
    on_off = 1,
    brightness = 60,
    ignore_default = 1,
  })
  T.eq("and tells its level on the new range", levels(), { 75 })
  noRange()
  bulb({ brightness = 20 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  reply()
  run(1000)
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  mark()
  run(3000)
  T.eq("a ramp to 50 % with the same Max set on the way is told at its end at 62", levels(), { 62 })
  for _, c in ipairs({
    { "a ramp", "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 } },
    { "a scene step", "ACTIVATE_SCENE", { SCENE_ID = 7 } },
  }) do
    noRange()
    bulb()
    proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(50, 4000) })
    proxy(c[2], c[3])
    reply()
    run(1000)
    proxy("SET_MAX_ON_LEVEL", { LEVEL = 100 })
    run(1000)
    mark()
    proxy("SET_BRIGHTNESS_STOP")
    T.eq(c[1] .. " from full under that Max to level 50, the Max put back on the way, stops where it is", {
      answered(),
      levels(),
    }, { { on_off = 1, brightness = 70, ignore_default = 1 }, { 70 } })
    proxy("CLEAR_ALL_SCENES")
  end
  noRange()
  bulb({ brightness = 20 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  reply()
  run(1000)
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  mark()
  run(3000)
  T.eq("run to its end, it is told at full's level on the new range", levels(), { 100 })
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("and level 100 then goes out, from full to the Max", answered(), {
    on_off = 1,
    brightness = 80,
    ignore_default = 1,
  })

  -- A strip the driver walks: its walk runs on to full, and level 100 then goes out.
  noRange()
  walked({ brightness = 20 }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  serve(1000, 250)
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  mark()
  local steps = each(serve(4000, 250), "brightness")
  T.eq("a walk with a Max of 80 set a quarter of the way still ends at full", steps[#steps], 100)
  T.eq("and is told at its end at 100", levels(), { 100 })
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("then level 100 takes the strip to the Max", flying(), { { device_on = true, brightness = 80 } })
  serve(1000, 250)
  noRange()
  walked({}, NO_POLLS)
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 1, RATE = 4000 })
  serve(300, 250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  serve(1000, 250)
  T.eq("a walk down from full stopped above the Max holds the strip at 98 %, shown at 100", strip.brightness, 98)
  T.eq("which is level 100", levels(), { 100 })
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("and level 100 then takes it to the Max", flying(), { { device_on = true, brightness = 80 } })
  serve(1000, 250)
  noRange()
end

T.section("a stop in a fade to or from off under a Min or Max holds the light where it is")
do
  local TOGGLE, CLICK = 2, 2
  forgetSetup()
  local OFF = { on_off = 0, dft_on_state = { brightness = 100, hue = 0, saturation = 100, color_temp = 0 } }

  --- A Kasa bulb on 20 to 80, at the Max or off, faded to `to` over 4 s and `ms` in.
  local function fading(lightState, to, ms)
    noRange()
    bulb(lightState)
    onLevels(20, 80)
    if lightState.on_off ~= 0 then
      proxy("SET_LEVEL", { LEVEL = 100 })
      reply()
    end
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = to, RATE = 4000 })
    reply()
    run(ms)
    mark()
  end

  --- What a stop `ms` into such a fade sends, and the level told.
  local function stopped(lightState, to, ms)
    fading(lightState, to, ms)
    proxy("SET_BRIGHTNESS_STOP")
    return answered(), levels()
  end
  T.eq("on 20 to 80, a fade to off from the Max stopped half way holds the bulb at 40 %, level 34", {
    stopped({}, 0, 2000),
  }, { { on_off = 1, brightness = 40, ignore_default = 1 }, { 34 } })
  T.eq("stopped under the Min, past half way to it: the bulb goes to the Min, level 1", {
    stopped({}, 0, 3200),
  }, { { on_off = 1, brightness = 20, ignore_default = 1 }, { 1 } })
  T.eq("short of half way to the Min: off", { stopped({}, 0, 3600) }, { { on_off = 0 }, { 0 } })
  T.eq("a fade up from off stopped under the Min, past half way to it: the Min", {
    stopped(OFF, 100, 800),
  }, { { on_off = 1, brightness = 20, ignore_default = 1 }, { 1 } })
  T.eq("and short of half way: off", { stopped(OFF, 100, 400) }, { { on_off = 0 }, { 0 } })

  -- A toggle counts the light on until it is half a level from off.
  fading({}, 0, 3600)
  proxy("TOGGLE")
  T.eq("a toggle where a stop turns the bulb off counts it on, and turns it off", answered(), { on_off = 0 })
  fading({}, 0, 3600)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS })
  local pressed = answered()
  run(110)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = CLICK })
  T.eq("and so do a press and click of the Toggle button", { pressed, flying(), levels() }, {
    { on_off = 0 },
    {},
    { 0, 0 },
  })
  fading({}, 0, 3600)
  RFP.DO_CLICK(301, "DO_CLICK", {})
  T.eq("and a click of a Toggle Button Link", answered(), { on_off = 0 })

  -- Under a Max of 50 from 70 %, where the bulb is outside the range.
  noRange()
  bulb({ brightness = 70 })
  proxy("SET_MAX_ON_LEVEL", { LEVEL = 50 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  reply()
  run(2000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("from 70 % under a Max of 50, a fade to off stopped half way holds the bulb at 35 %", answered(), {
    on_off = 1,
    brightness = 35,
    ignore_default = 1,
  })
  T.eq("which is level 70 on 1 to 50", levels(), { 70 })
  noRange()
end

T.section(
  "with a range a strip the driver walks passes under the Min to and from off, as a light fading by itself does"
)
do
  --- A strip the driver walks, on 20 to 80.
  local function ranged(fields)
    noRange()
    walked(fields, NO_POLLS)
    onLevels(20, 80)
  end
  forgetSetup()
  -- With no range the line is the levels themselves, half percents included.
  noRange()
  walked({ device_on = false }, NO_POLLS)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  serve(3000, 250)
  T.eq("with no range, 3 s into a walk from off to 60 % over 6 s the step in flight is 29 %, from 28.5", flying(), {
    { device_on = true, brightness = 29 },
  })
  ranged({ device_on = false })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  local up = { 2, 7, 12, 17, 22, 27, 32, 37, 42, 47, 52, 57, 62, 67, 72, 77, 80 }
  T.eq(
    "on 20 to 80, a walk up from off to level 100 runs from under the Min to the Max",
    each(serve(5000, 250), "brightness"),
    up
  )
  T.eq("and is told at its end at 100", levels(), { 100 })

  --- A strip at the Max of 20 to 80 walked to off over 4 s and stopped `ms` in: the step in flight, what is sent
  --- after it, the level told and where the strip ends.
  local function stopped(ms)
    ranged({ brightness = 80 })
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
    serve(ms, 250)
    local step = flying()[1]
    mark()
    proxy("SET_BRIGHTNESS_STOP")
    local commands, after = serve(4000, 250), {}
    for i = 2, #commands do
      after[#after + 1] = commands[i].sent
    end
    return step, after, levels(), { strip.device_on, strip.brightness }
  end
  T.eq("stopped half way: the step in flight, 43 %, holds, and is told as level 39", { stopped(2000) }, {
    { device_on = true, brightness = 43 },
    {},
    { 39 },
    { true, 43 },
  })
  T.eq("stopped at a step under the Min, past half way to it: the strip goes to the Min, level 1", { stopped(3200) }, {
    { device_on = true, brightness = 18 },
    { { device_on = true, brightness = 20 } },
    { 1 },
    { true, 20 },
  })
  T.eq("short of half way to the Min: off", { stopped(3900) }, {
    { device_on = true, brightness = 3 },
    { { device_on = false } },
    { 0 },
    { false, 3 },
  })

  -- A strip below the Min, set there elsewhere, stopped before its first step: it holds where it is.
  ranged({ brightness = 5 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a strip at 5 %, under the Min, stopped before its first step to off: nothing sent, shown at 1", {
    flying(),
    levels(),
  }, { {}, { 1 } })

  -- A walk between two lit levels from under the Min holds a stop where it is.
  ranged({ brightness = 5 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  serve(400, 250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a strip at 5 % walked up to level 50 and stopped still under the Min holds there, shown at 1", {
    each(serve(1000, 250), "brightness"),
    levels(),
  }, { { 9 }, { 1 } })

  -- A command at a step under the Min starts from the strip's place: no dip toward off.
  ranged({ brightness = 80 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  serve(3600, 250)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  local steps = each(serve(3000, 250), "brightness")
  T.eq(
    "a level over 2 s at a step of 13 % is told as a ramp from 1",
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    { 1 }
  )
  T.eq(
    "and walks up from that step to level 50's 50 %, never under it",
    steps,
    { 13, 15, 19, 24, 29, 33, 38, 42, 47, 50 }
  )
  noRange()
end

T.section("dimming is declared in driver.xml, and turned off at run time for a light that only switches")
do
  local DIMMING = { "dimmer", "set_level", "supports_target", "supports_brightness_stop", "ramp_level" }
  local f = assert(io.open(HERE .. "/../drivers/tplink_light/driver.xml", "rb"))
  local xml = f:read("*a")
  f:close()
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

T.eq("no timer or reply handler raised", errors, {})

T.finish()
