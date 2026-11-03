--- The TP-Link Outlet driver's keypad links and power events for each output.
---
--- An output's On, Off and Toggle Button Links switch it from a keypad, and
--- their LEDs follow it. Its In Use and Idle events fire when its power rises
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

package.loaded["lib.klap"] = {
  new = function()
    return setmetatable({}, Transport)
  end,
}
package.loaded["lib.legacy"] = {
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
  ["Output 1 In Use Above (W)"] = "0",
  ["Output 1 Idle Below (W)"] = "0",
}

dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
ShimLateInit()

--- The binding of one of output 1's keypad links.
local function link(key)
  return bindings:getDynamicBinding("button", "output_1_" .. key)
end

--- LED states told to each keypad link, as { key = { states } }.
local leds = {}
function SendToProxy(idBinding, strCommand, tParams)
  if strCommand == "MATCH_LED_STATE" then
    for _, key in ipairs({ "on", "off", "toggle" }) do
      if link(key) ~= nil and link(key).bindingId == idBinding then
        leds[key] = leds[key] or {}
        table.insert(leds[key], tParams.STATE)
      end
    end
  end
end

--- The LEDs told and the relay states set since the last call.
local function drain()
  local told, set = leds, plug.set
  leds, plug.set = {}, {}
  return told, set
end

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

T.section("a keypad bound to a link is told its LED, and the LEDs follow the output")
do
  drain()
  for _, key in ipairs({ "on", "off", "toggle" }) do
    OnBindingChanged(link(key).bindingId, "BUTTON_LINK", true, 900, 1)
  end
  T.eq("off: only the Off LED lit", (drain()), { on = { false }, off = { true }, toggle = { false } })
  plug.relay = 1
  EC.RefreshNow()
  T.eq("switched on at the plug", (drain()), { on = { true }, off = { false }, toggle = { true } })
  EC.RefreshNow()
  T.eq("a poll with no change tells nothing", (drain()), {})
end

T.section("a press switches the output once, whichever of push and click a keypad sends")
do
  ReceivedFromProxy(link("off").bindingId, "DO_PUSH", {})
  ReceivedFromProxy(link("off").bindingId, "DO_CLICK", {})
  local told, set = drain()
  T.eq("Off: a tap switches the output off once", set, { 0 })
  T.eq("and the LEDs follow", told, { on = { false }, off = { true }, toggle = { false } })
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

T.finish()
