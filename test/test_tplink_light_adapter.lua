--- The TP-Link light adapter against the light library's contract: the device facts each way of reaching a
--- light declares, every command of the contract's cases as a Kasa bulb, a Tapo light and an outlet are sent
--- it, each report as the library takes it, and what a poll crossed by a command and a failed send do.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_tplink_light_adapter.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local F = require("c4_fixtures")
local D = require("light_drivers")
local deferred = require("deferred")
local Cases = require("light_contract_cases")
local Color = require("lib.light.color")

local OUTLET_BINDING = 1
local BULB_SERVICE = "smartlife.iot.smartbulb.lightingservice"

---------------------------------------------------------------------------
-- Stand-in transports: each request is recorded and answered at once, or
-- held while `holding` is set, until the test settles it.
---------------------------------------------------------------------------

--- A request a transport was given.
--- @class TplinkWireRequest
--- @field payload table
--- @field d Deferred

--- @type TplinkWireRequest[]
local requests = {}
--- @type TplinkWireRequest[]
local held = {}
local holding = false
--- @type fun(payload: table): table|nil nil fails the request.
local answer = function()
  return {}
end

local Transport = {}
Transport.__index = Transport

function Transport:configure() end

function Transport:reset() end

function Transport:connect()
  return deferred.new():resolve({})
end

function Transport:request(payload)
  local request = { payload = payload, d = deferred.new() }
  requests[#requests + 1] = request
  if holding then
    held[#held + 1] = request
    return request.d
  end
  local response = answer(payload)
  if response == nil then
    return request.d:reject({ error = "no response" })
  end
  return request.d:resolve(response)
end

local function newTransport()
  return setmetatable({}, Transport)
end

package.loaded["tplink.klap"] = { new = newTransport }
package.loaded["tplink.legacy"] = { new = newTransport }
package.loaded["tplink.tpap"] = {
  new = newTransport,
  discover = function()
    return deferred.new():reject({ error = "no answer to TPAP discover" })
  end,
  supports = function()
    return false
  end,
}
package.loaded["tplink.light_adapter"] = nil
package.loaded["tplink.light_probe"] = nil

local TplinkLightAdapter = require("tplink.light_adapter")
local IotBulb = require("tplink.iotbulb")
local SmartBulb = require("tplink.smartbulb")

local clock = F.virtualClock()
D.seedProperties(D.xml(D.root(), "tplink_light") or "")

--- What the outlet binding is sent.
--- @type {command: string, params: table}[]
local outletSent = {}
local priorSend = C4.SendToProxy
C4.SendToProxy = function(self, id, command, params, ...)
  if tonumber(id) == OUTLET_BINDING then
    outletSent[#outletSent + 1] = { command = command, params = params }
    return
  end
  return priorSend(self, id, command, params, ...)
end

--- The host's side: what the adapter declared, reported and lost.
--- @class TplinkWireHost : TplinkLightHost
--- @field declared LightDevice[]
--- @field reports LightReport[]
--- @field losts integer

--- @return TplinkWireHost
local function newHost()
  local host = { declared = {}, reports = {}, losts = 0 }
  function host:declare(device)
    self.declared[#self.declared + 1] = device
  end
  function host:report(report)
    self.reports[#self.reports + 1] = report
  end
  function host:lost()
    self.losts = self.losts + 1
  end
  function host:restart() end
  return host
end

---------------------------------------------------------------------------
-- The lights
---------------------------------------------------------------------------

--- A Kasa color bulb's light_state.
--- @param fields table|nil
--- @return table
local function kasaState(fields)
  local state = { on_off = 1, mode = "normal", brightness = 60, hue = 0, saturation = 100, color_temp = 2700 }
  for k, v in pairs(fields or {}) do
    state[k] = v
  end
  return state
end

--- @param lightState table
--- @return table
local function sysinfo(lightState)
  return {
    system = {
      get_sysinfo = {
        err_code = 0,
        model = "KL130(US)",
        is_dimmable = 1,
        is_color = 1,
        is_variable_color_temp = 1,
        light_state = lightState,
      },
    },
  }
end

--- A Tapo color light's get_device_info result.
--- @param fields table|nil
--- @return table
local function tapoInfo(fields)
  local info = {
    device_on = true,
    brightness = 60,
    hue = 0,
    saturation = 100,
    color_temp = 2700,
    color_temp_range = { 2500, 6500 },
  }
  for k, v in pairs(fields or {}) do
    info[k] = v
  end
  return info
end

--- The Tapo light's own fades, as get_on_off_gradually_info answers.
local GRADUAL = {
  on_state = { enable = true, duration = 2 },
  off_state = { enable = true, duration = 1 },
  change_state = { enable = true },
}

--- A light's answer to any request: get_sysinfo and get_device_info as given, the rest taken.
--- @param iot table|nil
--- @param smart table|nil
local function answering(iot, smart)
  answer = function(payload)
    if Select(payload, "system", "get_sysinfo") then
      return iot
    end
    if payload.method == "get_device_info" then
      return { error_code = 0, result = smart }
    end
    if payload.method == "get_on_off_gradually_info" then
      return { error_code = 0, result = GRADUAL }
    end
    if payload.method then
      return { error_code = 0 }
    end
    return { [BULB_SERVICE] = { transition_light_state = { err_code = 0 } } }
  end
end

--- A Kasa bulb found on the legacy port.
--- @return TplinkLightAdapter adapter
--- @return TplinkWireHost host
local function kasa()
  local host = newHost()
  local adapter = TplinkLightAdapter.new(host, OUTLET_BINDING)
  answering(sysinfo(kasaState()), nil)
  local bulb = IotBulb:new(adapter.link.legacy)
  bulb:poll():next(function(result)
    adapter:adopt("iot", bulb, "Legacy", result.entity, result.state)
  end)
  clock.run(100)
  requests = {}
  return adapter, host
end

--- A Tapo light found over KLAP, with the Fades property as given.
--- @param fades "Driver"|"Light"
--- @return TplinkLightAdapter adapter
--- @return TplinkWireHost host
local function tapo(fades)
  local host = newHost()
  Properties["Fades"] = fades
  local adapter = TplinkLightAdapter.new(host, OUTLET_BINDING)
  local info = tapoInfo()
  answering(nil, info)
  adapter.link.smart = adapter.link.klap
  adapter:adopt("smart", nil, "SMART", SmartBulb.entity(info), SmartBulb.state(info))
  clock.run(100)
  requests = {}
  return adapter, host
end

--- A light bound to an outlet, which has told it the lamp's state.
--- @return TplinkLightAdapter adapter
--- @return TplinkWireHost host
local function outlet()
  local host = newHost()
  C4:Bind(9001, 4001, 0, OUTLET_BINDING, "TPLINK_LIGHT")
  local adapter = TplinkLightAdapter.new(host, OUTLET_BINDING)
  adapter:start()
  adapter:outletUpdate({
    entity = SerializeSafe({ supported_color_modes = { 1 } }),
    state = SerializeSafe({ state = false }),
  })
  outletSent = {}
  return adapter, host
end

--- The last request since the mark, and how many went.
--- @return table|nil payload
--- @return integer count
local function lastRequest()
  local last = requests[#requests]
  local count = #requests
  requests = {}
  return last and last.payload, count
end

---------------------------------------------------------------------------
-- What a command should put on the wire
---------------------------------------------------------------------------

--- @param level number 0-1.
--- @return integer|nil
local function percent(level)
  local p = math.floor(level * 100 + 0.5)
  return p >= 1 and math.min(100, p) or nil
end

--- The color fields both schemas name a command's color by, on a light of this Kelvin range.
--- @param color LightColor
--- @param kelvinMin integer
--- @param kelvinMax integer
--- @return table
local function colorWire(color, kelvinMin, kelvinMax)
  if color.mode == "cct" then
    local kelvin = color.kelvin or Color.kelvin(color.x, color.y)
    -- Through mireds and back, as the command carries it.
    kelvin = math.floor(1e6 / Color.kelvinToMireds(kelvin) + 0.5)
    return { color_temp = math.max(kelvinMin, math.min(kelvinMax, kelvin)) }
  end
  local h, s = C4:ColorXYtoHSV(color.x, color.y)
  return { hue = math.floor(h + 0.5) % 360, saturation = math.floor(s + 0.5), color_temp = 0 }
end

--- Whether the wire's color fields are the command's, a hue or saturation within 1 of it.
--- @param got table
--- @param want table
--- @return boolean
local function sameColor(got, want)
  if want.color_temp ~= 0 then
    return got.color_temp == want.color_temp and got.hue == nil
  end
  return got.color_temp == 0
    and got.hue ~= nil
    and math.min(math.abs(got.hue - want.hue), 360 - math.abs(got.hue - want.hue)) <= 1
    and math.abs(got.saturation - want.saturation) <= 1
end

--- Check what a Kasa bulb was sent for a command.
--- @param name string
--- @param cmd LightCommand
--- @param payload table|nil
local function checkKasa(name, cmd, payload)
  local params = Select(payload, BULB_SERVICE, "transition_light_state")
  if not T.check(name .. ": goes out as transition_light_state", type(params) == "table", T.show(payload)) then
    return
  end
  T.eq(name .. ": on or off", params.on_off, cmd.on and 1 or 0)
  local level = cmd.setsLevel and cmd.on and percent(cmd.level) or nil
  T.eq(name .. ": at its level, or none", params.brightness, level)
  if cmd.setsColor and cmd.color then
    T.check(name .. ": in its color", sameColor(params, colorWire(cmd.color, 2500, 9000)), T.show(params))
  else
    T.eq(name .. ": with no color", { params.hue, params.color_temp }, {})
  end
  local ms = cmd.transitionMs or 0
  T.eq(name .. ": over its time, up to 60 s", params.transition_period, ms > 0 and math.min(ms, 60000) or nil)
end

--- Check what a Tapo light was sent for a command.
--- @param name string
--- @param cmd LightCommand
--- @param payload table|nil
local function checkTapo(name, cmd, payload)
  if not T.eq(name .. ": goes out as set_device_info", Select(payload, "method"), "set_device_info") then
    return
  end
  local params = payload.params
  T.eq(name .. ": on or off", params.device_on, cmd.on)
  T.eq(name .. ": at its level, or none", params.brightness, cmd.setsLevel and cmd.on and percent(cmd.level) or nil)
  if cmd.setsColor and cmd.color then
    T.check(name .. ": in its color", sameColor(params, colorWire(cmd.color, 2500, 6500)), T.show(params))
  else
    T.eq(name .. ": with no color", { params.hue, params.color_temp }, {})
  end
  T.eq(name .. ": with no fade time, which a Tapo light takes none of", params.transition_period, nil)
end

---------------------------------------------------------------------------
T.section("the device facts each way of reaching a light declares")
---------------------------------------------------------------------------
do
  local adapter, host = kasa()
  local device = host.declared[#host.declared]
  T.truthy("a Kasa bulb dims", device.dims)
  T.truthy("and has color", device.color)
  T.eq("its white range is its model's", device.cct, { minK = 2500, maxK = 9000 })
  T.eq("it fades itself, linearly, up to 60 s", device.fade, { kind = "device", curve = "linear", maxMs = 60000 })
  T.eq("it holds a color while off", device.colorWhileOff, "hold")
  T.eq("in 100 steps", device.levelSteps, 100)
  T.eq(
    "its polls show the target, seen within 2 s, and a refresh polls it",
    device.feedback,
    { shows = "target", waitMs = 2000, refresh = true }
  )
  T.eq("it declared once", #host.declared, 1)
  T.eq("and reported once", #host.reports, 1)
  T.truthy("connected", adapter.connected)

  local _, driverHost = tapo("Driver")
  local walk = driverHost.declared[#driverHost.declared]
  T.eq("a Tapo light with Fades on Driver: the driver walks its fades", walk.fade, { kind = "walk", stepMs = 100 })
  T.eq("its white range is the one it reports", walk.cct, { minK = 2500, maxK = 6500 })

  local own, ownHost = tapo("Light")
  T.eq("with Fades on Light it is declared once its own fades are read", #ownHost.declared, 1)
  T.eq(
    "with their lengths, the change taken as a second",
    ownHost.declared[1].fade,
    { kind = "own", own = { onMs = 2000, offMs = 1000, changeMs = 1000 } }
  )
  T.eq("and reported once", #ownHost.reports, 1)
  own:setFades("Driver")
  clock.run(100)
  T.eq("Fades set to Driver declares it walked", ownHost.declared[#ownHost.declared].fade, {
    kind = "walk",
    stepMs = 100,
  })

  local _, outletHost = outlet()
  local plug = outletHost.declared[#outletHost.declared]
  T.falsy("a light on an outlet does not dim", plug.dims)
  T.falsy("and has no color", plug.color)
  T.eq("and no white range", plug.cct, nil)
  T.eq("its fade is the default", plug.fade, nil)
end

---------------------------------------------------------------------------
T.section("the contract's cases: each command goes out to a Kasa bulb, a Tapo light and an outlet as it says")
---------------------------------------------------------------------------
for _, case in ipairs(Cases.list) do
  for i, sent in ipairs(case.commands) do
    local cmd = sent.command
    local name = string.format("%s, command %d", case.name, i)

    local adapter = kasa()
    T.eq(name .. ": a Kasa bulb's send returns no rest", adapter:send(cmd), nil)
    clock.run(100)
    local payload, count = lastRequest()
    T.eq(name .. ": one request", count, 1)
    checkKasa(name .. " (Kasa)", cmd, payload)

    local smart = tapo("Driver")
    smart:send(cmd)
    clock.run(100)
    payload, count = lastRequest()
    T.eq(name .. ": one request to a Tapo light", count, 1)
    checkTapo(name .. " (Tapo)", cmd, payload)

    local plug = outlet()
    plug:send(cmd)
    local body = outletSent[1] and DeserializeSafe(outletSent[1].params.body)
    T.eq(name .. " (outlet): one ENTITY_COMMAND, its on or off alone", {
      #outletSent,
      outletSent[1] and outletSent[1].command,
      body,
    }, { 1, "ENTITY_COMMAND", { has_state = true, state = cmd.on } })
  end
end

---------------------------------------------------------------------------
T.section("each report is a push of where the light heads, in its white or its color")
---------------------------------------------------------------------------
do
  local adapter, host = kasa()
  answering(sysinfo(kasaState({ brightness = 40, color_temp = 4000 })), nil)
  adapter:poll()
  clock.run(100)
  local report = host.reports[#host.reports]
  T.eq("a Kasa poll is a push", report.kind, "push")
  T.eq("on at its level", { report.on, report.level }, { true, 0.4 })
  T.eq("a white is reported as one", { report.color.mode, report.color.kelvin }, { "cct", 4000 })
  local x, y = Color.kelvinToXY(4000)
  T.truthy("at that white's point", math.abs(report.color.x - x) < 1e-9 and math.abs(report.color.y - y) < 1e-9)

  answering(
    sysinfo({
      on_off = 0,
      dft_on_state = { mode = "normal", brightness = 70, hue = 240, saturation = 100, color_temp = 0 },
    }),
    nil
  )
  adapter:poll()
  clock.run(100)
  report = host.reports[#host.reports]
  T.eq("an off Kasa bulb reports off, at the level it comes on at", { report.on, report.level }, { false, 0.7 })
  local bx, by = C4:ColorHSVtoXY(240, 100, 100)
  T.truthy(
    "in the color it comes on in, as xy",
    report.color.mode == "xy" and math.abs(report.color.x - bx) < 1e-6 and math.abs(report.color.y - by) < 1e-6,
    T.show(report.color)
  )

  local smart, smartHost = tapo("Driver")
  answering(nil, tapoInfo({ device_on = false, brightness = 25, hue = 120, saturation = 100, color_temp = 0 }))
  smart:poll()
  clock.run(100)
  report = smartHost.reports[#smartHost.reports]
  T.eq("a Tapo poll is a push, off at its level", { report.kind, report.on, report.level }, { "push", false, 0.25 })
  T.eq("in its color", report.color.mode, "xy")

  local plug, plugHost = outlet()
  plug:outletUpdate({
    entity = SerializeSafe({ supported_color_modes = { 1 } }),
    state = SerializeSafe({ state = true }),
  })
  report = plugHost.reports[#plugHost.reports]
  T.eq("an outlet's report is a push, on, with no level", { report.kind, report.on, report.level }, {
    "push",
    true,
    nil,
  })
  T.eq("and a refresh asks the outlet again", (function()
    outletSent = {}
    plug:refresh()
    return outletSent[1] and outletSent[1].command
  end)(), "REFRESH_STATE")
end

---------------------------------------------------------------------------
T.section("a poll a command crosses is not told, and the command goes once the poll is in")
---------------------------------------------------------------------------
do
  local adapter, host = kasa()
  local reports = #host.reports
  holding = true
  adapter:poll()
  local cmd = Cases.list[2].commands[1].command
  adapter:send(cmd)
  T.eq("the command waits for the poll in flight", #held, 1)
  holding = false
  local poll = table.remove(held, 1)
  poll.d:resolve(sysinfo(kasaState({ brightness = 90 })))
  clock.run(100)
  T.eq("the poll's answer, from before the command, is not told", #host.reports, reports)
  local payload, count = lastRequest()
  T.eq("then the command goes", count, 2)
  checkKasa("the command that waited", cmd, payload)
end

---------------------------------------------------------------------------
T.section("a Tapo light that fails a set reads lost; a Kasa bulb's failed command is left to the poll")
---------------------------------------------------------------------------
do
  local smart, host = tapo("Driver")
  answer = function()
    return nil
  end
  smart:send(Cases.list[2].commands[1].command)
  clock.run(100)
  T.eq("a failed set_device_info loses the Tapo light", host.losts, 1)
  T.falsy("and it is not connected", smart.connected)

  local adapter, kasaHost = kasa()
  answer = function()
    return nil
  end
  adapter:send(Cases.list[2].commands[1].command)
  clock.run(100)
  T.eq("a failed Kasa command loses nothing", kasaHost.losts, 0)
  answer = function()
    return nil
  end
  adapter:poll()
  clock.run(100)
  T.eq("a failed poll loses it", kasaHost.losts, 1)
end

C4.SendToProxy = priorSend
clock.restore()
T.finish()
