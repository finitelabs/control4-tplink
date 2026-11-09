--- The TP-Link Outlet driver's side of its connection to a TP-Link Light: what
--- the light is told on a bind, on REFRESH_STATE, on a change at the plug and
--- when the plug goes offline, and what an ENTITY_COMMAND does.
---
--- The plug is a stand-in on the legacy port that keeps its own relay state
--- and answers at once when it is reachable.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_light.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local constants = require("constants")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

--- The plug: its relay (0 or 1), whether it answers, and each state it is set to.
local plug = { relay = 0, reachable = true, set = {} }

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
      system = { get_sysinfo = { err_code = 0, model = "HS103", alias = "Lamp", relay_state = plug.relay } },
    })
  end
  -- No energy meter.
  return deferred.new():resolve({})
end

local function newTransport()
  return setmetatable({}, Transport)
end

package.loaded["tplink.klap"] = { new = newTransport }
package.loaded["tplink.legacy"] = { new = newTransport }
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
function C4:GetProjectProperty()
  return "000000"
end

Properties = {
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["IP Address"] = "192.0.2.24",
  ["Protocol"] = "Legacy",
  ["Poll Rate (Seconds)"] = "5",
  ["Model"] = "",
  ["Device Name"] = "",
  ["MAC Address"] = "",
  ["Firmware"] = "",
  ["WiFi RSSI"] = "",
}

dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")

--- Every message sent to the light connection, decoded as the light driver
--- reads it: { command, entity, state }.
local LIGHT
local told = {}
function SendToProxy(idBinding, strCommand, tParams)
  if idBinding == LIGHT then
    told[#told + 1] = {
      strCommand,
      DeserializeSafe(Select(tParams, "entity")),
      DeserializeSafe(Select(tParams, "state")),
    }
  end
end

--- The relay states set on the plug and the light messages since the last call.
local function drain()
  local set, messages = plug.set, told
  plug.set, told = {}, {}
  return set, messages
end

--- What the light is told of the plug's output, on or off.
local function update(on)
  return { "UPDATE_STATE", { supported_color_modes = { constants.LightColorMode.COLOR_MODE_ON_OFF } }, { state = on } }
end

--- Send a command to the light connection as the bound light driver would.
local function command(strCommand, body)
  ReceivedFromProxy(LIGHT, strCommand, { body = body and SerializeSafe(body) or nil })
end

ShimLateInit()
LIGHT = bindings:getDynamicBinding("light", "output_1").bindingId
drain()

T.section("a bind tells the light the output's state, as an on/off light")
do
  OnBindingChanged(LIGHT, "TPLINK_LIGHT", true, 900, 1)
  T.eq("off", select(2, drain()), { update(false) })
end

T.section("REFRESH_STATE tells it again")
do
  command("REFRESH_STATE")
  local set, messages = drain()
  T.eq("nothing is set on the plug", set, {})
  T.eq("the state", messages, { update(false) })
end

T.section("a change at the plug reaches the light")
do
  plug.relay = 1
  EC.RefreshNow()
  T.eq("on", select(2, drain()), { update(true) })
end

T.section("ENTITY_COMMAND with a state switches the output")
do
  command("ENTITY_COMMAND", { has_state = true, state = false })
  local set, messages = drain()
  T.eq("the plug is switched off", set, { 0 })
  T.eq("and the light told", messages, { update(false) })
  command("ENTITY_COMMAND", { has_state = true, state = true })
  set, messages = drain()
  T.eq("and on", set, { 1 })
  T.eq("and the light told", messages, { update(true) })
  command("ENTITY_COMMAND", { brightness = 0.5 })
  set, messages = drain()
  T.eq("a command with no state sets nothing", set, {})
  T.eq("and tells nothing", messages, {})
end

T.section("the plug going offline disconnects the light")
do
  plug.reachable = false
  EC.RefreshNow()
  T.eq("UPDATE_DISCONNECT", select(2, drain()), { { "UPDATE_DISCONNECT" } })
  plug.reachable = true
  EC.RefreshNow()
  T.eq("and its next answer tells the state", select(2, drain()), { update(true) })
end

T.section("while the plug is offline a bind or REFRESH_STATE tells the light nothing")
do
  plug.reachable = false
  EC.RefreshNow()
  drain()
  command("REFRESH_STATE")
  T.eq("REFRESH_STATE", select(2, drain()), {})
  OnBindingChanged(LIGHT, "TPLINK_LIGHT", true, 900, 1)
  T.eq("a bind", select(2, drain()), {})
  plug.reachable = true
  EC.RefreshNow()
  T.eq("the next answer still tells the state", select(2, drain()), { update(true) })
end

T.finish()
