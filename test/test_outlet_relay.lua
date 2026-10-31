--- The TP-Link Outlet driver's relay connection: what a bound relay driver is
--- told, and when.
---
--- CLOSED and OPENED fire the bound driver's programming, so they go out only
--- when an output changes. A bind and GET_STATE get STATE_CLOSED or
--- STATE_OPENED, which set the same state without firing it, and nothing
--- while the state is unknown.
---
--- The plug is a stand-in on the legacy port that keeps its own relay state
--- and answers at once when it is reachable.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_relay.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local values = require("lib.values")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

--- The plug: its relay (0 or 1), whether it answers, and each state it is set to.
local plug = { relay = 0, reachable = false, set = {} }

local Transport = {}
Transport.__index = Transport

function Transport:configure() end

function Transport:reset() end

function Transport:connect()
  return deferred.new()
end

function Transport:request(request)
  if not plug.reachable then
    return deferred.new()
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

package.loaded["lib.klap"] = { new = newTransport }
package.loaded["lib.legacy"] = { new = newTransport }
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

-- As an earlier run left them: the relay connection, and the output off.
local RELAY = bindings:getOrAddDynamicBinding("relay", "output_1", "CONTROL", true, "Output 1 Relay", "RELAY").bindingId
values:update("Output 1 State", false, "BOOL")

dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")

--- Every message sent to the relay connection, as { binding, command, type }.
local told = {}
function SendToProxy(idBinding, strCommand, _, strMessage)
  if idBinding == RELAY then
    told[#told + 1] = { idBinding, strCommand, strMessage }
  end
end

--- The relay states set on the plug and the relay messages since the last call.
local function drain()
  local set, messages = plug.set, told
  plug.set, told = {}, {}
  return set, messages
end

--- Send a command to the relay connection as its bound driver would.
local function command(strCommand, tParams)
  ReceivedFromProxy(RELAY, strCommand, tParams or {})
end

local function bind()
  OnBindingChanged(RELAY, "RELAY", true, 900, 1)
end

local function unbind()
  OnBindingChanged(RELAY, "RELAY", false, 900, 1)
end

--- The plug's own relay changes, and the driver polls it.
local function switchAtPlug(relay)
  plug.relay = relay
  EC.RefreshNow()
end

T.section("before the plug first answers, the relay connection is told nothing")
do
  OnDriverInit()
  bind()
  T.eq("a bind", select(2, drain()), {})
  command("GET_STATE")
  local set, messages = drain()
  T.eq("GET_STATE sets nothing on the plug", set, {})
  T.eq("GET_STATE", messages, {})
end

plug.reachable = true
OnDriverLateInit()
drain()

T.section("a bind and GET_STATE tell the known state without firing programming")
do
  bind()
  T.eq("bind while off", select(2, drain()), { { RELAY, "STATE_OPENED", "NOTIFY" } })
  command("GET_STATE")
  local set, messages = drain()
  T.eq("GET_STATE while off sets nothing on the plug", set, {})
  T.eq("GET_STATE while off", messages, { { RELAY, "STATE_OPENED", "NOTIFY" } })

  switchAtPlug(1)
  drain()
  bind()
  T.eq("bind while on", select(2, drain()), { { RELAY, "STATE_CLOSED", "NOTIFY" } })
  command("GET_STATE")
  set, messages = drain()
  T.eq("GET_STATE while on sets nothing on the plug", set, {})
  T.eq("GET_STATE while on", messages, { { RELAY, "STATE_CLOSED", "NOTIFY" } })

  unbind()
  T.eq("an unbind", select(2, drain()), {})
end

T.section("a change at the plug fires programming, a poll with no change does not")
do
  switchAtPlug(0)
  T.eq("switched off at the plug", select(2, drain()), { { RELAY, "OPENED", "NOTIFY" } })
  switchAtPlug(0)
  T.eq("polled, still off", select(2, drain()), {})
  switchAtPlug(1)
  T.eq("switched on at the plug", select(2, drain()), { { RELAY, "CLOSED", "NOTIFY" } })
  switchAtPlug(1)
  T.eq("polled, still on", select(2, drain()), {})
end

T.section("other commands are ignored")
do
  for _, unknown in ipairs({ "GET_RELAY_STATE", "QUERY", "FOO" }) do
    command(unknown)
  end
  local set, messages = drain()
  T.eq("nothing set on the plug", set, {})
  T.eq("nothing told", messages, {})
end

T.section("the switching commands switch the plug and fire programming on a change")
do
  switchAtPlug(0)
  drain()
  for _, case in ipairs({
    { "ON", { 1 }, { { RELAY, "CLOSED", "NOTIFY" } } },
    { "ON", { 1 }, {} },
    { "OFF", { 0 }, { { RELAY, "OPENED", "NOTIFY" } } },
    { "OFF", { 0 }, {} },
    { "CLOSE", { 1 }, { { RELAY, "CLOSED", "NOTIFY" } } },
    { "OPEN", { 0 }, { { RELAY, "OPENED", "NOTIFY" } } },
    { "TOGGLE", { 1 }, { { RELAY, "CLOSED", "NOTIFY" } } },
    { "TOGGLE", { 0 }, { { RELAY, "OPENED", "NOTIFY" } } },
  }) do
    command(case[1])
    local set, messages = drain()
    T.eq(case[1] .. " sets the plug", set, case[2])
    T.eq(case[1] .. " tells", messages, case[3])
  end
end

T.section("TRIGGER closes the relay, and opens it again after TIME")
do
  command("TRIGGER", { TIME = "500" })
  local set, messages = drain()
  T.eq("closes", set, { 1 })
  T.eq("tells CLOSED", messages, { { RELAY, "CLOSED", "NOTIFY" } })
  ShimFireTimers()
  set, messages = drain()
  T.eq("opens when the time is up", set, { 0 })
  T.eq("tells OPENED", messages, { { RELAY, "OPENED", "NOTIFY" } })

  command("TRIGGER")
  set, messages = drain()
  T.eq("with no TIME, closes", set, { 1 })
  T.eq("and tells CLOSED", messages, { { RELAY, "CLOSED", "NOTIFY" } })
  ShimFireTimers()
  set, messages = drain()
  T.eq("and stays closed", set, {})
  T.eq("telling nothing more", messages, {})
end

T.finish()
