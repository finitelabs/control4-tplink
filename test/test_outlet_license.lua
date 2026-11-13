--- The TP-Link Outlet's DriverCentral build under its license gate, with the real cloud client and a fake Cloud
--- driver: licensed, it connects and switches; five minutes without a license, it lets go of the plug and sends
--- nothing more, and its outputs keep their state with no event; a license connects it again at once.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_license.lua

local T = require("testlib")

require("c4_shim")
local cloud = require("dc_cloud")
local bindings = require("lib.bindings")
local values = require("lib.values")
local deferred = require("deferred")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

--- Every request the plug was sent, each held until the test answers it.
local sent = {}
local Transport = {}
Transport.__index = Transport
function Transport:configure() end
function Transport:reset() end
function Transport:connect()
  return deferred.new()
end
function Transport:request(request)
  local d = deferred.new()
  sent[#sent + 1] = { request = request, d = d }
  return d
end
local function newTransport()
  return setmetatable({}, Transport)
end
package.loaded["tplink.klap"] = { new = newTransport }
package.loaded["tplink.legacy"] = { new = newTransport }

local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  elseif section == "version" then
    return "20261104"
  end
  return configInfo(self, section)
end
function C4:GetVersionInfo()
  return { version = "3.3.0.0-res" }
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
local fired = {}
function C4:FireEventByID(id)
  fired[#fired + 1] = id
end

Properties = {
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["Cloud Status"] = "",
  ["Automatic Updates"] = "Off",
  ["IP Address"] = "192.0.2.24",
  ["Protocol"] = "Legacy",
  ["Poll Rate (Seconds)"] = "5",
  ["Energy Poll Rate (Seconds)"] = "0",
  ["Model"] = "",
  ["Device Name"] = "",
  ["MAC Address"] = "",
  ["Firmware"] = "",
  ["WiFi RSSI"] = "",
}

local RELAY = bindings:getOrAddDynamicBinding("relay", "output_1", "CONTROL", true, "Output 1 Relay", "RELAY").bindingId
values:update("Output 1 State", false, "BOOL")

--- Run the Lua file at `path` as the DriverCentral build compiles it: the lines its directives leave out are blanked.
local function dofileDriverCentral(path)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local directive, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if directive then
      stack[#stack + 1] = including
      including = including and (name == "DRIVERCENTRAL") == (directive == "ifdef")
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    lines[#lines + 1] = including and line or ""
  end
  f:close()
  assert(load(table.concat(lines, "\n"), "@" .. path))()
end

--- The last request that asks `key` under system, or nil.
local function lastAsking(key)
  for i = #sent, 1, -1 do
    if Select(sent[i].request, "system", key) ~= nil then
      return sent[i]
    end
  end
end

--- Answer the plug's last get_sysinfo as an off one-output plug.
local function answerSysinfo()
  lastAsking("get_sysinfo").d:resolve({
    system = {
      get_sysinfo = { err_code = 0, model = "ZX100(US)", alias = "Lamp", mac = "02:00:00:00:00:0A", relay_state = 0 },
    },
  })
end

--- `n` rounds of 10 s: one of the client's pings, then every due timer, the gate's read among them.
local function tick(n)
  for _ = 1, n or 1 do
    cloud.poll(1)
    ShimFireTimers()
  end
end

--- Whether a relay CLOSE reaches the plug.
local function closeSends()
  local before = #sent
  ReceivedFromProxy(RELAY, "CLOSE", {})
  local request = sent[#sent]
  if #sent > before then
    request.d:resolve({ system = { set_relay_state = { err_code = 0 } } })
    return true
  end
  return false
end

cloud.answer = { AC = 0, AS = "Invalid License" }
dofileDriverCentral(HERE .. "/../drivers/tplink_outlet/driver.lua")
OnDriverInit()
OnDriverLateInit("DIT_ADDED")
answerSysinfo()

T.section("Without a license the outlet runs five minutes after its load, then lets go of the plug")
do
  T.eq("the real client heard: DC_X", DC_X, 0)
  T.eq("connected while the grace runs", Properties["Driver Status"], "Connected (Legacy)")
  tick(29)
  T.eq("29 reads of 0: a relay CLOSE still switches", closeSends(), true)
  local events = #fired
  tick()
  T.eq("the 30th read stops it: Driver Status", Properties["Driver Status"], "No active license")
  local before = #sent
  T.eq("a relay CLOSE sends nothing", closeSends(), false)
  ExecuteCommand("Turn_Output_On", { Output = "1" })
  ExecuteCommand("LUA_ACTION", { ACTION = "Reconnect" })
  ExecuteCommand("LUA_ACTION", { ACTION = "RefreshNow" })
  tick(10)
  T.eq("nor does Control4 programming, an action or a poll", #sent, before)
  T.eq("Driver Status after a Reconnect", Properties["Driver Status"], "No active license")
  T.eq("programming reads it as not connected", TC.DEVICE_CONNECTED(), false)
  T.eq("and the stop fires no event", #fired, events)
end

T.section("A license connects it again at once")
do
  local before = #sent
  cloud.say({ AC = 1, AS = "License Activated" })
  T.eq("it probes the plug without waiting for a read", #sent > before and lastAsking("get_sysinfo") ~= nil, true)
  answerSysinfo()
  T.eq("Driver Status", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("a relay CLOSE switches again", closeSends(), true)
  T.eq("programming reads it as connected", TC.DEVICE_CONNECTED(), true)
end

T.section("A Cloud driver update does not stop it")
do
  cloud.answer = { AC = 1, AS = "License Activated" }
  cloud.say({ AC = 0, AS = "Cloud driver removed, please install cloud driver." })
  cloud.silent = true
  tick(3)
  cloud.silent = false
  tick()
  T.eq("DC_X once the new Cloud driver answers", DC_X, 1)
  tick(40)
  T.eq("still connected", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("a relay CLOSE still switches", closeSends(), true)
end

T.finish()
