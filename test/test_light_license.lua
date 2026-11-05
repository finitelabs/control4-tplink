--- The TP-Link Light's DriverCentral build under its license gate, with the real cloud client and a fake Cloud
--- driver: five minutes without a license it stops reaching the bulb and shows offline at the level it had, with no
--- Light Off; a license starts it again at once.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_light_license.lua

local T = require("testlib")

require("c4_shim")
local cloud = require("dc_cloud")
local deferred = require("deferred")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local PROXY = 5001

--- Every request the bulb was sent, each held until the test answers it.
local held = {}
local Transport = {}
Transport.__index = Transport
function Transport:configure() end
function Transport:reset() end
function Transport:connect()
  return deferred.new()
end
function Transport:request(payload)
  local r = { payload = payload, d = deferred.new() }
  held[#held + 1] = r
  return r.d
end
local function newTransport()
  return setmetatable({}, Transport)
end
package.loaded["tplink.klap"] = { new = newTransport }
package.loaded["tplink.legacy"] = { new = newTransport }
package.loaded["tplink.tpap"] = {
  new = newTransport,
  discover = function()
    return deferred.new()
  end,
}

function C4:ColorXYtoHSV(x, y)
  return x * 360, y * 100
end
function C4:ColorHSVtoXY(h, s)
  return h / 360, s / 100
end
function C4:ColorCCTtoXY(k)
  return k / 10000, 0.4
end
function C4:ColorXYtoCCT(x)
  return x * 10000
end
function C4:GetProxyDevices()
  return 727
end
function C4:GetBoundProviderDevice()
  return 0
end
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
--- What the light proxy is told, as command and params.
local told = {}
function C4:SendToProxy(id, command, params)
  if id == PROXY then
    told[#told + 1] = { command = command, params = params or {} }
  end
end

Properties = {
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["Cloud Status"] = "",
  ["Automatic Updates"] = "Off",
  ["IP Address"] = "192.0.2.30",
  ["MAC Address"] = "",
  ["Protocol"] = "Legacy",
  ["TP-Link Username"] = "",
  ["TP-Link Password"] = "",
  ["Poll Rate (Seconds)"] = "5",
}

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

local LIGHT_STATE = { on_off = 1, brightness = 60, hue = 0, saturation = 100, color_temp = 0 }

--- The bulb's answer to a probe or a poll: a color bulb that is on at 60 %.
local function sysinfo()
  return {
    system = {
      get_sysinfo = {
        err_code = 0,
        model = "KL130(US)",
        mac = "02:00:00:00:00:1A",
        is_dimmable = 1,
        is_color = 1,
        is_variable_color_temp = 1,
        light_state = LIGHT_STATE,
      },
    },
  }
end

--- Answer the bulb's last probe.
local function answerProbe()
  table.remove(held).d:resolve(sysinfo())
end

--- Answer every request held, as a bulb that answers at once would.
local function answerAll()
  while #held > 0 do
    local r = table.remove(held, 1)
    if Select(r.payload, "system", "get_sysinfo") ~= nil then
      r.d:resolve(sysinfo())
    else
      r.d:resolve({ ["smartlife.iot.smartbulb.lightingservice"] = { transition_light_state = LIGHT_STATE } })
    end
  end
end

--- `n` rounds of 10 s: one of the client's pings, then every due timer, the gate's read among them.
local function tick(n)
  for _ = 1, n or 1 do
    cloud.poll(1)
    ShimFireTimers()
    answerAll()
  end
end

--- Whether a proxy ON reaches the bulb.
local function onSends()
  answerAll()
  ReceivedFromProxy(PROXY, "ON", {})
  local reached = false
  for _, r in ipairs(held) do
    if Select(r.payload, "smartlife.iot.smartbulb.lightingservice", "transition_light_state") then
      reached = true
    end
  end
  answerAll()
  return reached
end

--- Each brightness the proxy was told since `from`.
local function brightnessesSince(from)
  local out = {}
  for i = from + 1, #told do
    if told[i].command == "LIGHT_BRIGHTNESS_CHANGED" then
      out[#out + 1] = told[i].params.LIGHT_BRIGHTNESS_CURRENT
    end
  end
  return out
end

cloud.answer = { AC = 0, AS = "Invalid License" }
dofileDriverCentral(HERE .. "/../drivers/tplink_light/driver.lua")
OnDriverInit()
OnDriverLateInit("DIT_ADDED")
answerProbe()

T.section("Without a license the light runs five minutes after its load, then stops reaching the bulb")
do
  T.eq("connected while the grace runs", Properties["Driver Status"], "Connected (Legacy)")
  tick(29)
  T.eq("29 reads of 0: a proxy ON still reaches the bulb", onSends(), true)
  local mark = #told
  tick()
  T.eq("the 30th read stops it: Driver Status", Properties["Driver Status"], "No active license")
  T.eq("the proxy is told it is offline", Select(told, #told, "command"), "ONLINE_CHANGED")
  T.eq("with no brightness change, so no Light Off", brightnessesSince(mark), {})
  T.eq("a proxy ON sends nothing", onSends(), false)
  local pushed = #told
  ReceivedFromProxy(1, "UPDATE_STATE", {
    entity = SerializeSafe({ supported_color_modes = { require("constants").LightColorMode.COLOR_MODE_BRIGHTNESS } }),
    state = SerializeSafe({ state = false }),
  })
  ReceivedFromProxy(1, "UPDATE_DISCONNECT", {})
  ReceivedFromProxy(1, "UPDATE_STATE", {
    entity = SerializeSafe({ supported_color_modes = { require("constants").LightColorMode.COLOR_MODE_BRIGHTNESS } }),
    state = SerializeSafe({ state = true, brightness = 1 }),
  })
  T.eq("a bound outlet's pushes tell the proxy nothing", #told, pushed)
  T.eq("and leave Driver Status", Properties["Driver Status"], "No active license")
  local asked = 0
  local request = Transport.request
  function Transport.request(...)
    asked = asked + 1
    return request(...)
  end
  ExecuteCommand("LUA_ACTION", { ACTION = "Reconnect" })
  tick(10)
  Transport.request = request
  T.eq("nor does a Reconnect or a poll", asked, 0)
  T.eq("Driver Status after a Reconnect", Properties["Driver Status"], "No active license")
end

T.section("A license starts it again at once")
do
  held = {}
  cloud.say({ AC = 1, AS = "License Activated" })
  T.eq("it probes the bulb without waiting for a read", #held > 0, true)
  answerProbe()
  T.eq("Driver Status", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("a proxy ON reaches the bulb again", onSends(), true)
end

T.finish()
