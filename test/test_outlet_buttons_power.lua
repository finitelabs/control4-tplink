--- The TP-Link Outlet driver's keypad links and power events for each output.
---
--- An output's On, Off and Toggle Button Links switch it from a keypad, and
--- their LEDs follow it in the driver's button colors, which the first start
--- takes from the project. Its In Use and Idle events fire when its power rises
--- above one level and falls below another; a reading the device has when the
--- driver starts or reconnects, or when a level changes, fires neither.
---
--- The plug is a stand-in on the legacy port with one output and a meter.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_buttons_power.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local bindings = require("lib.bindings")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

--- The plug: its relay (0 or 1), its power in milliwatts, whether it answers,
--- and each relay state it is set to.
local plug = { relay = 0, mw = 0, reachable = true, set = {} }

local Transport = {}
Transport.__index = Transport

function Transport:configure() end

function Transport:reset() end

function Transport:connect()
  return deferred.new()
end

function Transport:request(request)
  if not plug.reachable then
    return deferred.new():reject({ error = "no answer" })
  end
  local set = Select(request, "system", "set_relay_state")
  if set then
    plug.relay = set.state
    plug.set[#plug.set + 1] = set.state
    return deferred.new():resolve({ system = { set_relay_state = { err_code = 0 } } })
  end
  if Select(request, "system", "get_sysinfo") then
    return deferred.new():resolve({
      system = { get_sysinfo = { err_code = 0, model = "ZX100(US)", alias = "Lamp", relay_state = plug.relay } },
    })
  end
  if Select(request, "emeter", "get_realtime") then
    return deferred.new():resolve({ emeter = { get_realtime = { err_code = 0, power_mw = plug.mw } } })
  end
  return deferred.new():resolve({})
end

package.loaded["tplink.klap"] = {
  new = function()
    return setmetatable({}, Transport)
  end,
}
package.loaded["tplink.legacy"] = {
  new = function()
    return setmetatable({}, Transport)
  end,
}
-- Loaded unprocessed, OnDriverInit runs both sides of --#ifdef DRIVERCENTRAL.
package.loaded["cloud-client-byte"] = true

local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return config(self, section)
end

function C4:UpdateProperty(name, value)
  Properties[name] = value
end

-- The project's button LED colors: dev's, with Top's changed so the first start's are not the driver's defaults.
local project = {
  TopLEDOn = "ff8800",
  TopLEDOff = "112233",
  BottomLEDOn = "000000",
  BottomLEDOff = "0000ff",
  ToggleLEDOn = "0000ff",
  ToggleLEDOff = "000000",
}
function C4:GetProjectProperty(name)
  return project[name]
end

--- Every event fired, by id.
local fired = {}
function C4:FireEventByID(id)
  fired[#fired + 1] = id
end

Properties = {
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["IP Address"] = "192.0.2.24",
  ["Protocol"] = "Legacy",
  ["Poll Rate (Seconds)"] = "5",
  ["Energy Poll Rate (Seconds)"] = "5",
  ["Model"] = "",
  ["Device Name"] = "",
  ["MAC Address"] = "",
  ["Firmware"] = "",
  ["WiFi RSSI"] = "",
  ["Output 1 State"] = "",
  ["Output 1 In Use Above (W)"] = "0",
  ["Output 1 Idle Below (W)"] = "0",
  ["Output 1 Hold (s)"] = "0",
  ["Button Lit Color"] = "0,0,255",
  ["Button Unlit Color"] = "0,0,0",
}

dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
ShimLateInit()

--- The binding of one of output 1's keypad links.
local function link(key)
  return bindings:getDynamicBinding("button", "output_1_" .. key)
end

--- LED states told to each keypad link, as { key = { states } }, and the
--- colors each was told, as { key = { on, off } }, the last of them.
local leds, colors = {}, {}
function SendToProxy(idBinding, strCommand, tParams)
  for _, key in ipairs({ "on", "off", "toggle" }) do
    if link(key) ~= nil and link(key).bindingId == idBinding then
      if strCommand == "MATCH_LED_STATE" then
        leds[key] = leds[key] or {}
        table.insert(leds[key], tParams.STATE)
      elseif strCommand == "BUTTON_COLORS" then
        colors[key] = { tParams.ON_COLOR, tParams.OFF_COLOR }
      end
    end
  end
end

--- The LEDs told and the relay states set since the last call, and the colors told.
local function drain()
  local told, set, toldColors = leds, plug.set, colors
  leds, plug.set, colors = {}, {}, {}
  return told, set, toldColors
end

--- Each link's colors, on and off, for a lit and an unlit color: the Off link's are swapped.
local function linkColors(lit, unlit)
  return { on = { lit, unlit }, off = { unlit, lit }, toggle = { lit, unlit } }
end

--- Each link's colors from the project's Top button colors.
local PROJECT_COLORS = linkColors("ff8800", "112233")

--- Set a property as Composer does: the value, then the driver's handler.
local function setProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

--- The plug draws this many watts, and the driver reads it: the In Use (21)
--- and Idle (31) events that fire.
local function draw(watts)
  plug.mw = watts * 1000
  fired = {}
  EC.RefreshNow()
  local power = {}
  for _, id in ipairs(fired) do
    if id > 20 and id < 40 then
      power[#power + 1] = id
    end
  end
  return power
end

T.section("the first start takes the project's Top button colors into the button color properties")
T.eq(
  "lit and unlit, as Composer shows them",
  { Properties["Button Lit Color"], Properties["Button Unlit Color"] },
  { "255,136,0", "17,34,51" }
)

T.section("each output gets On, Off and Toggle keypad links")
do
  for key, name in pairs({ on = "On", off = "Off", toggle = "Toggle" }) do
    T.truthy(name, link(key))
  end
  local names = {}
  for _, binding in pairs(ShimDynamicBindings()) do
    if binding.class == "BUTTON_LINK" then
      names[#names + 1] = binding.name
    end
  end
  table.sort(names)
  T.eq(
    "named for the output",
    names,
    { "Output 1 Off Button Link", "Output 1 On Button Link", "Output 1 Toggle Button Link" }
  )
end

T.section("a keypad bound to a link is told nothing until it asks, and the LEDs follow the output")
do
  drain()
  for _, key in ipairs({ "on", "off", "toggle" }) do
    OnBindingChanged(link(key).bindingId, "BUTTON_LINK", true, 900, 1)
  end
  local told, _, toldColors = drain()
  T.eq("nothing at the bind: the keypad asks", { told, toldColors }, { {}, {} })
  plug.relay = 1
  EC.RefreshNow()
  told, _, toldColors = drain()
  T.eq("switched on at the plug: on, on every link", told, { on = { true }, off = { true }, toggle = { true } })
  T.eq("and no colors again", toldColors, {})
  T.eq("its State property reads On", Properties["Output 1 State"], "On")
  T.eq("while programming reads 1", Variables["Output 1 State"], "1")
  EC.RefreshNow()
  T.eq("a poll with no change tells nothing", (drain()), {})
end

T.section("a keypad that asks a link for its colors is told them and the output's state on it")
do
  drain()
  ReceivedFromProxy(link("off").bindingId, "REQUEST_BUTTON_COLORS", {})
  local told, set, toldColors = drain()
  T.eq(
    "the Off link, with the output on: the colors swapped, on, and nothing switched",
    { toldColors, told, set },
    { { off = PROJECT_COLORS.off }, { off = { true } }, {} }
  )
  ReceivedFromProxy(link("toggle").bindingId, "REQUEST_BUTTON_COLORS", {})
  told, set, toldColors = drain()
  T.eq(
    "the Toggle link: the colors, on",
    { toldColors, told },
    { { toggle = PROJECT_COLORS.toggle }, { toggle = { true } } }
  )
end

T.section("after a driver update each link is told its colors and the output's state at the first poll")
do
  ShimUpdateDriver()
  dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
  drain()
  ShimLateInit()
  local told, _, toldColors = drain()
  T.eq("the button colors for its button", toldColors, PROJECT_COLORS)
  T.eq("and on, on every link", told, { on = { true }, off = { true }, toggle = { true } })

  -- Switched off at the plug while the driver was down: the first poll is a change.
  ShimUpdateDriver()
  dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
  drain()
  plug.relay = 0
  ShimLateInit()
  told, _, toldColors = drain()
  T.eq("switched while down: the colors too", toldColors, PROJECT_COLORS)
  T.eq("and off, on every link", told, { on = { false }, off = { false }, toggle = { false } })
  plug.relay = 1
  EC.RefreshNow()
  drain()
end

T.section("a changed button color reaches every bound keypad at once, and an update keeps it")
do
  drain()
  setProperty("Button Lit Color", "0,255,0")
  local told, set, toldColors = drain()
  T.eq("each link is told its colors with the new lit color", toldColors, linkColors("00ff00", "112233"))
  T.eq(
    "and the output's state, with nothing switched",
    { told, set },
    { { on = { true }, off = { true }, toggle = { true } }, {} }
  )
  setProperty("Button Unlit Color", "64,0,64")
  told, set, toldColors = drain()
  T.eq("the unlit color too", toldColors, linkColors("00ff00", "400040"))

  -- The project's colors change, then the driver is updated: the first start's are not taken again.
  project.TopLEDOn, project.TopLEDOff = "abcdef", "010203"
  ShimUpdateDriver()
  dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
  drain()
  ShimLateInit()
  told, set, toldColors = drain()
  T.eq(
    "after an update the properties keep the colors set",
    { Properties["Button Lit Color"], Properties["Button Unlit Color"] },
    { "0,255,0", "64,0,64" }
  )
  T.eq("and each link is told them at the first poll", toldColors, linkColors("00ff00", "400040"))
end

T.section("Reset Button Colors takes the project's colors again and tells every keypad")
do
  drain()
  EC.ResetButtonColors()
  local told, set, toldColors = drain()
  T.eq(
    "the properties take the project's Top button colors",
    { Properties["Button Lit Color"], Properties["Button Unlit Color"] },
    { "171,205,239", "1,2,3" }
  )
  T.eq("each link is told them", toldColors, linkColors("abcdef", "010203"))
  T.eq(
    "and the output's state, with nothing switched",
    { told, set },
    { { on = { true }, off = { true }, toggle = { true } }, {} }
  )
  project.TopLEDOn, project.TopLEDOff = "ff8800", "112233"
end

T.section("a press switches the output once, whichever of push and click a keypad sends")
do
  ReceivedFromProxy(link("off").bindingId, "DO_PUSH", {})
  ReceivedFromProxy(link("off").bindingId, "DO_CLICK", {})
  local told, set = drain()
  T.eq("Off: a tap switches the output off once", set, { 0 })
  T.eq("and the LEDs follow", told, { on = { false }, off = { false }, toggle = { false } })
  ShimFireTimers()
  drain()
  ReceivedFromProxy(link("toggle").bindingId, "DO_CLICK", {})
  T.eq("Toggle: a click alone", select(2, drain()), { 1 })
  ShimFireTimers()
  drain()
  ReceivedFromProxy(link("on").bindingId, "DO_PUSH", {})
  T.eq("On: a push alone, already on, sets it on", select(2, drain()), { 1 })
  ShimFireTimers()
  drain()
  ReceivedFromProxy(link("on").bindingId, "DO_RELEASE", {})
  T.eq("a release does nothing", select(2, drain()), {})
  ShimFireTimers()
  drain()
  ReceivedFromProxy(link("toggle").bindingId, "DO_PUSH", {})
  EC.RefreshNow()
  ReceivedFromProxy(link("toggle").bindingId, "DO_CLICK", {})
  T.eq("a poll between a tap's push and click: one switch", #select(2, drain()), 1)
end

T.section("with both levels at 0 an output's power fires nothing")
do
  T.eq("100 W", draw(100), {})
  T.eq("and makes no In Use variable", Variables["Output 1 In Use"], nil)
end

T.section("In Use fires above the In Use level, Idle below the Idle level")
do
  setProperty("Output 1 In Use Above (W)", "50")
  setProperty("Output 1 Idle Below (W)", "5")
  T.eq("the first reading fires nothing", draw(100), {})
  T.eq("and sets In Use", Variables["Output 1 In Use"], "1")
  T.eq("between the levels: still in use", draw(30), {})
  T.eq("below Idle: Idle", draw(2), { 31 })
  T.eq("In Use cleared", Variables["Output 1 In Use"], "0")
  T.eq("between the levels: still idle", draw(30), {})
  T.eq("above In Use: In Use", draw(60), { 21 })
  T.eq("set", Variables["Output 1 In Use"], "1")
end

T.section("a reconnect, or a level changed, takes the next reading as the output's state")
do
  plug.reachable = false
  EC.RefreshNow()
  plug.reachable = true
  T.eq("idle when it is read again: nothing fires", draw(2), {})
  T.eq("but In Use is cleared", Variables["Output 1 In Use"], "0")
  T.eq("and the next rise fires", draw(60), { 21 })
  setProperty("Output 1 In Use Above (W)", "80")
  T.eq("after a level change: nothing fires", draw(60), {})
  T.eq("idle, under the new level", Variables["Output 1 In Use"], "0")
end

T.section("one level alone works both ways")
do
  setProperty("Output 1 Idle Below (W)", "0")
  draw(10)
  T.eq("above it: In Use", draw(90), { 21 })
  T.eq("below it: Idle", draw(70), { 31 })
end

T.section("with a hold time the power must stay past a level that long")
do
  local clock = 0
  local getTime = C4.GetTime
  function C4:GetTime()
    return clock
  end
  --- The plug draws this many watts at this many seconds, and the driver reads it.
  local function at(seconds, watts)
    clock = seconds * 1000
    return draw(watts)
  end
  setProperty("Output 1 In Use Above (W)", "50")
  setProperty("Output 1 Idle Below (W)", "5")
  setProperty("Output 1 Hold (s)", "60")
  at(0, 90)
  T.eq("in use", Variables["Output 1 In Use"], "1")
  T.eq("below Idle: nothing yet", at(10, 2), {})
  T.eq("still below at 50 s: nothing yet", at(60, 2), {})
  T.eq("back between the levels: the wait starts again", at(65, 30), {})
  T.eq("below again", at(70, 2), {})
  T.eq("59 s later: nothing", at(129, 2), {})
  T.eq("60 s later: Idle", at(130, 2), { 31 })
  T.eq("In Use cleared", Variables["Output 1 In Use"], "0")
  T.eq("a spike above In Use: nothing yet", at(140, 90), {})
  T.eq("gone at the next reading: nothing", at(145, 2), {})
  T.eq("and nothing later", at(300, 2), {})
  T.eq("still idle", Variables["Output 1 In Use"], "0")
  setProperty("Output 1 Hold (s)", "0")
  C4.GetTime = getTime
end

T.section("an update from a build that kept State without labels fires no On or Off")
do
  local persist = require("lib.persist")
  local stored = persist:get("Values")
  stored["Output 1 State"].labels = nil
  persist:set("Values", stored)
  ShimUpdateDriver()
  dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
  fired = {}
  ShimLateInit()
  EC.RefreshNow()
  local switched = {}
  for _, id in ipairs(fired) do
    if id <= 6 or (id > 50 and id <= 56) then
      switched[#switched + 1] = id
    end
  end
  T.eq("no On or Off event", switched, {})
  T.eq("the State property has its label again", Properties["Output 1 State"], plug.relay == 1 and "On" or "Off")
end

T.finish()
