--- The TP-Link light's connection, in one of two ways:
---   Outlet: bound to a TP-Link Outlet output, the outlet reports the lamp's
---     state (UPDATE_STATE) and takes its commands (ENTITY_COMMAND).
---   Direct: the IP Address and TP-Link credential properties point at a Kasa
---     or Tapo light. light_probe.lua finds which protocol and schema it
---     answers; from then on it is polled, and serves one request at a time.
--- What it hears it tells its host, the light driver.

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")
local Follower = require("tplink.discovery").Follower
local Klap = require("tplink.klap")
local Legacy = require("tplink.legacy")
local Tpap = require("tplink.tpap")
local SmartBulb = require("tplink.smartbulb")
local TplinkLightProbe = require("tplink.light_probe")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("lib.utils")

local DIRECT_POLL_TIMER = "DirectPoll"

--- How long a request in flight is waited for, in milliseconds: past the
--- transports' own timeouts, 10 s for a KLAP post and 5 s on the legacy port.
--- @type number
local DIRECT_ANSWER_MS = 15000

local DIRECT_ANSWER_TIMER = "DirectAnswer"

--- How long a light takes over its own fade between two states while it is
--- on, in milliseconds. It reports no length for it: measured on a Tapo strip.
--- @type number
local OWN_CHANGE_MS = 1000

--- The color a light was given while off, owed to its next on.
local PENDING_COLOR = "pending_color"

--- Driver Status while the light is searched for on the network.
local LOOKING = "Looking for the device on the network..."

--- The direct schema found at the light: "smart" (get_device_info and
--- set_device_info, mapped by smartbulb.lua) or "iot" (sysinfo and
--- transition_light_state, mapped by an IotBulb).
--- @alias TplinkLightSchema "smart"|"iot"

--- Who makes a light's fades, from the Fades property: "Driver" in steps, or
--- "Light" at the light's own lengths.
--- @alias TplinkLightFades "Driver"|"Light"

--- What the connection tells the light driver; the driver implements each.
--- @class TplinkLightHost
--- @field update fun(self: TplinkLightHost, entity: TplinkLightEntity, state: TplinkLightState, news: boolean?) The light's state as it reports it. news: it is not where the driver sent it, as another hand has moved it.
--- @field lost fun(self: TplinkLightHost) The light stopped answering.
--- @field offline fun(self: TplinkLightHost) A start found no light: the proxy is told it is offline.
--- @field step fun(self: TplinkLightHost) The light is free to take a fade's next step.
--- @field fadesRead fun(self: TplinkLightHost) The light's own fades were read, or could not be: the proxy is told the rates.
--- @field restart fun(self: TplinkLightHost, retry: boolean?) Start the connection again, and the light's state with it.

--- The direct-mode transports.
--- @class TplinkLightLink
--- @field klap Klap KLAP v2 hashing: SMART-firmware devices and KL-series bulbs on newer KLAP firmware.
--- @field klapV1 Klap KLAP v1 hashing: KL-series bulbs whose KLAP firmware uses the MD5-based hashes.
--- @field legacy Legacy Port 9999: KL-series bulbs on original firmware.
--- @field tpap Tpap TPAP: a light whose account has Third-Party Compatibility off.
--- @field smart Klap|Tpap The session SMART-schema requests go through.

--- What a SMART light holds, as it was sent or read since the last command
--- from Control4.
--- @class TplinkSmartHeld
--- @field device_on boolean?
--- @field brightness number?
--- @field hue number?
--- @field saturation number?
--- @field color_temp number?

--- A light's own fades, in milliseconds, once they are read: on from off,
--- off, and change, between two states while on. 0 for one it has not.
--- @class TplinkOwnFades
--- @field on integer?
--- @field off integer?
--- @field change integer?
--- @field due boolean? The light is to be asked for them.

--- One of the light's own fades, as get_on_off_gradually_info names it.
--- @class TplinkFadeSwitch
--- @field enable boolean|integer?
--- @field duration integer? Seconds.

--- The light's own fades being switched on, one request each.
--- @class TplinkFadeRead
--- @field names string[] The fades, in the order they are switched on.
--- @field info table<string, TplinkFadeSwitch> Each, by name.
--- @field one boolean An older light with one switch for all its fades.

--- A request in flight.
--- @class TplinkLightFlight
--- @field generation integer The start it was made in.
--- @field over boolean Its answer, its failure or its timeout is in.

--- @class TplinkLightAdapter
--- @field host TplinkLightHost
--- @field outletBinding integer The binding to a TP-Link Outlet output.
--- @field link TplinkLightLink
--- @field follower Follower Follows the light to a new address by its MAC.
--- @field statusBefore string? Driver Status before a search for the light.
--- @field misses integer Polls in a row the light has not answered.
--- @field schema TplinkLightSchema?
--- @field bulb IotBulb? The IOT schema's mapping, for "iot".
--- @field transport string? "Outlet", "SMART", "KLAP", "TPAP" or "Legacy", for Driver Status.
--- @field connected boolean The direct light answers.
--- @field generation integer Counts the starts: an attempt, and the answer to a poll or a command, does nothing once it has moved on.
--- @field detecting boolean A start is still probing. The poll timer's retry waits for it.
--- @field busy boolean A request is in flight. The rest wait for it, in an order of their own.
--- @field waiting TplinkLightOpts? The command waiting for the request in flight, every later one merged in.
--- @field pollWaiting boolean A poll waits for the request in flight.
--- @field commands integer Counts the commands made. A poll sent before the latest reads the light as it was before it.
--- @field pendingColor TplinkHeldColor? The color the light was given while off, which it would drop. It is held, and stored, and goes out with the next command that turns the light on.
--- @field smartHeld TplinkSmartHeld?
--- @field entity TplinkLightEntity? What the light last reported it can do, for the Kelvin range it is sent.
--- @field fades TplinkLightFades? Who makes a fade. nil: the light, over the time a command carries.
--- @field ownFades TplinkOwnFades
local TplinkLightAdapter = {}
TplinkLightAdapter.__index = TplinkLightAdapter

--- The fields of a light command that name its color.
--- @type string[]
TplinkLightAdapter.COLOR_FIELDS = {
  "has_rgb",
  "red",
  "green",
  "blue",
  "has_color_temperature",
  "color_temperature",
  "has_color_mode",
  "color_mode",
}

--- @param host TplinkLightHost
--- @param outletBinding integer
--- @return TplinkLightAdapter
function TplinkLightAdapter.new(host, outletBinding)
  local self = setmetatable({}, TplinkLightAdapter)
  self.host = host
  self.outletBinding = outletBinding
  self.link = {
    klap = Klap:new(),
    klapV1 = Klap:new({ authVersion = 1 }),
    legacy = Legacy:new(),
    tpap = Tpap:new(),
  }
  self.link.smart = self.link.klap
  self.follower = Follower:new(function(address)
    self:moved(address)
  end, function(looking)
    self:looking(looking)
  end)
  self.misses = 0
  self.connected = false
  self.generation = 0
  self.detecting = false
  self.busy = false
  self.pollWaiting = false
  self.commands = 0
  self.ownFades = {}
  return self
end

--- Whether the outlet binding is connected.
--- @return boolean
function TplinkLightAdapter:bound()
  local provider = C4:GetBoundProviderDevice(C4:GetDeviceID(), self.outletBinding)
  return provider ~= nil and provider ~= 0
end

--- A search found the light at another address. A light bound to an outlet
--- has no address of its own.
--- @param address string
function TplinkLightAdapter:moved(address)
  if address == Properties["IP Address"] or self:bound() then
    return
  end
  log:info("The light moved to %s", address)
  UpdateProperty("IP Address", address)
  self.host:restart()
end

--- A search for the light started (true) or ended (false).
--- @param looking boolean
function TplinkLightAdapter:looking(looking)
  if looking then
    self.statusBefore = Properties["Driver Status"]
    UpdateProperty("Driver Status", LOOKING)
  elseif Properties["Driver Status"] == LOOKING then
    UpdateProperty("Driver Status", self.statusBefore or "")
  end
end

--- Show or hide the direct-mode network properties.
--- @param attrib number constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
local function setNetworkPropertiesAttribs(attrib)
  C4:SetPropertyAttribs("TP-Link Settings", attrib)
  C4:SetPropertyAttribs("IP Address", attrib)
  C4:SetPropertyAttribs("MAC Address", attrib)
  C4:SetPropertyAttribs("Protocol", attrib)
  C4:SetPropertyAttribs("TP-Link Username", attrib)
  C4:SetPropertyAttribs("TP-Link Password", attrib)
  C4:SetPropertyAttribs("Poll Rate (Seconds)", attrib)
end

--- No poll until the next start.
function TplinkLightAdapter:stopPolling()
  CancelTimer(DIRECT_POLL_TIMER)
end

--- Start reaching the light, through the outlet bound or at its address. The
--- bound outlet wins; the network properties are hidden while bound.
--- @param retry boolean? The poll timer trying again after no light was found.
function TplinkLightAdapter:start(retry)
  self:stopPolling()
  self.generation = self.generation + 1
  self.detecting = false
  self.connected = false
  self.transport = nil
  -- The request in flight and what waited were for the backend as it was.
  self.busy = false
  self.waiting = nil
  self.pollWaiting = false
  self.pendingColor = persist:get(PENDING_COLOR)
  self.fades = nil
  self.ownFades = {}
  self.entity = nil
  C4:SetPropertyAttribs("Fades", constants.HIDE_PROPERTY)

  if self:bound() then
    self.transport = "Outlet"
    -- The outlet reaches the light: there is no address to follow.
    self.follower:stop()
    setNetworkPropertiesAttribs(constants.HIDE_PROPERTY)
    SendToProxy(self.outletBinding, "REFRESH_STATE", {}, "NOTIFY")
    return
  end

  setNetworkPropertiesAttribs(constants.SHOW_PROPERTY)
  self.schema = nil
  self.bulb = nil

  local ip = Properties["IP Address"] or ""
  if IsEmpty(ip) then
    self.follower:stop()
    self:noLight("Bind to an outlet or set the IP Address property", retry)
    return
  end

  local config = {
    ip = ip,
    username = Properties["TP-Link Username"] or "",
    password = Properties["TP-Link Password"] or "",
  }
  self.link.klap:configure(config)
  self.link.klapV1:configure(config)
  self.link.tpap:configure(config)
  self.link.legacy:configure({ ip = ip })
  -- A probe the last attempt left on the legacy port would hold this one's.
  self.link.legacy:reset()

  if not TplinkLightProbe.new(self, retry, ip):start() then
    return
  end

  local pollSeconds = tointeger(Properties["Poll Rate (Seconds)"]) or 5
  SetTimer(DIRECT_POLL_TIMER, pollSeconds * ONE_SECOND, function()
    if self.schema ~= nil then
      self:poll()
    elseif not self.detecting then
      -- Detection found no light; keep retrying until the device answers.
      self.host:restart(true)
    end
  end, true)
end

--- End a start with no light to reach. A retry says nothing: the proxy was
--- told the light is offline when the attempt before it ended.
--- @param status string
--- @param retry boolean?
function TplinkLightAdapter:noLight(status, retry)
  UpdateProperty("Driver Status", status)
  if not retry then
    self.host:offline()
  end
end

--- Take the schema and transport a probe found, and the light's first answer.
--- @param schema TplinkLightSchema
--- @param bulb IotBulb?
--- @param name string Transport name for Driver Status.
--- @param entity TplinkLightEntity
--- @param state TplinkLightState
function TplinkLightAdapter:adopt(schema, bulb, name, entity, state)
  self:answered()
  UpdateProperty("MAC Address", self.follower:mac() or "")
  self.detecting = false
  self.schema = schema
  self.bulb = bulb
  self.transport = name
  self.connected = true
  -- A light on the SMART schema takes no fade time from a command, so who
  -- makes its fades is the installer's choice.
  if schema == "smart" then
    self.fades = Properties["Fades"] or "Driver"
    self.ownFades.due = true
    C4:SetPropertyAttribs("Fades", constants.SHOW_PROPERTY)
  end
  log:info("Using %s transport for direct control", name)
  self:report(entity, state)
  -- Its own fades are read now, where Fades leaves the fades to the light.
  self:next()
end

--- Tell the host the light's state.
--- @param entity TplinkLightEntity
--- @param state TplinkLightState
--- @param news boolean?
function TplinkLightAdapter:report(entity, state, news)
  self.entity = entity
  self.host:update(entity, state, news)
end

--- The outlet's report of the lamp's state.
--- @param tParams table<string, string> UPDATE_STATE's params: the entity and state, serialized.
function TplinkLightAdapter:outletUpdate(tParams)
  local entity = DeserializeSafe(Select(tParams, "entity"))
  local state = DeserializeSafe(Select(tParams, "state"))
  if IsEmpty(entity) or IsEmpty(state) then
    log:error("RFP.UPDATE_STATE called with invalid parameters: %s", tParams)
    return
  end
  self:report(entity, state)
end

--- Send a light command to the bound outlet.
--- @param opts TplinkLightOpts
function TplinkLightAdapter:sendOutlet(opts)
  SendToProxy(self.outletBinding, "ENTITY_COMMAND", {
    body = SerializeSafe(opts),
  }, "NOTIFY")
end

--- The light no longer answers: the driver shows it offline.
function TplinkLightAdapter:disconnect()
  if self.connected then
    self.connected = false
    self.entity = nil
    self.host:lost()
  end
end

--- A poll the light did not answer. From the third in a row the next poll
--- detects its protocol again, as a firmware update, a rollback or a reset
--- can change it; one slow answer keeps the session.
function TplinkLightAdapter:missed()
  self.misses = self.misses + 1
  self:disconnect()
  if self.misses >= 3 then
    self.schema = nil
    self.bulb = nil
  end
end

--- A poll the light answered.
function TplinkLightAdapter:answered()
  self.misses = 0
  self.follower:found()
end

--- Another device answers at the light's address: control nothing there, and
--- look for the light on the network.
function TplinkLightAdapter:another()
  self.misses = 0
  self.schema = nil
  self.bulb = nil
  self:disconnect()
  local ip = Properties["IP Address"] or ""
  log:warn("A device other than this light answers at %s", ip)
  UpdateProperty("Driver Status", "Disconnected: a different device is at " .. ip .. "; looking for this one")
  self.follower:lost()
end

--- Put a request in flight, and send what waited for it once its answer or
--- its failure is in. One with neither after DIRECT_ANSWER_MS has failed: a
--- request its transport never settled would hold every later one.
--- @param request Deferred
--- @param onAnswer fun(response: table)
--- @param onFail fun(err: TplinkLinkError)
function TplinkLightAdapter:fly(request, onAnswer, onFail)
  --- @type TplinkLightFlight
  local flight = { generation = self.generation, over = false }
  self.busy = true
  -- Set first: a request settled already lands inside next().
  SetTimer(DIRECT_ANSWER_TIMER, DIRECT_ANSWER_MS, function()
    self:land(flight, onFail, { error = "no answer from the light" })
  end)
  request:next(function(response)
    self:land(flight, onAnswer, response)
  end, function(err)
    self:land(flight, onFail, err)
  end)
end

--- A flight's answer, failure or timeout is in. Only the first counts, and
--- none from an earlier start.
--- @param flight TplinkLightFlight
--- @param handler fun(value: any)
--- @param value any
function TplinkLightAdapter:land(flight, handler, value)
  if flight.over or flight.generation ~= self.generation then
    return
  end
  flight.over = true
  CancelTimer(DIRECT_ANSWER_TIMER)
  self.busy = false
  handler(value)
  self:next()
end

--- The color held for a light, as a poll finds it: one that is off comes on in
--- it. A light turned on by another hand came on in the color it had, so the
--- hold is let go.
--- @param on boolean Whether the light is on.
--- @return TplinkHeldColor? held
function TplinkLightAdapter:heldColor(on)
  if on and self.pendingColor then
    self.pendingColor = nil
    persist:delete(PENDING_COLOR)
  end
  return self.pendingColor
end

--- Hold the color of a command that does not turn the light on, which the
--- light would drop, and add a held one to an on that names no color. Both
--- schemas name a color's params alike.
--- @param params TplinkHeldColor A request's params; the color is taken out when held.
--- @param on boolean? Whether the command turns the light on.
function TplinkLightAdapter:holdColor(params, on)
  local color = params.color_temp ~= nil
  if color and not on then
    self.pendingColor = { hue = params.hue, saturation = params.saturation, color_temp = params.color_temp }
    persist:set(PENDING_COLOR, self.pendingColor)
    params.hue, params.saturation, params.color_temp = nil, nil, nil
  elseif self.pendingColor and (color or on) then
    if not color then
      for field, value in pairs(self.pendingColor) do
        params[field] = value
      end
    end
    self.pendingColor = nil
    persist:delete(PENDING_COLOR)
  end
end

--- Forget the color held for the light: the light it was for may be gone.
function TplinkLightAdapter:forgetColor()
  persist:delete(PENDING_COLOR)
end

--- Take a poll's answer as what the light holds.
--- @param info TplinkSmartInfo
--- @return boolean moved Whether another hand has moved it: it is not what the
---   light held.
function TplinkLightAdapter:smartRead(info)
  local held = self.smartHeld or {}
  local now = {
    device_on = toboolean(info.device_on),
    brightness = tonumber_locale(info.brightness),
    hue = tonumber_locale(info.hue),
    saturation = tonumber_locale(info.saturation),
    color_temp = tonumber_locale(info.color_temp),
  }
  self.smartHeld = now
  local function moved(field)
    return held[field] ~= nil and held[field] ~= now[field]
  end
  if moved("device_on") or moved("brightness") or moved("color_temp") then
    return true
  end
  -- In a color temperature the light holds no hue of its own.
  return now.color_temp == 0 and (moved("hue") or moved("saturation"))
end

--- Poll the direct-mode light, and tell the host what it holds.
function TplinkLightAdapter:poll()
  if self.busy then
    self.pollWaiting = true
    return
  end
  local asked = self.commands

  if self.schema == "iot" and self.bulb ~= nil then
    self:fly(self.bulb:poll(self.pendingColor), function(result)
      self:iotPolled(result, asked)
    end, function(err)
      self:pollFailed("IOT bulb poll", err)
    end)
    return
  end

  self:fly(self.link.smart:request({ method = "get_device_info", params = {} }), function(response)
    self:smartPolled(response, asked)
  end, function(err)
    self:pollFailed("get_device_info", err)
  end)
end

--- An IOT light's answer to a poll.
--- @param result TplinkIotPoll
--- @param asked integer The commands made when the poll went out.
function TplinkLightAdapter:iotPolled(result, asked)
  if not self.follower:accepts(result.mac) then
    self:another()
    return
  end
  self:answered()
  self.connected = true
  if asked == self.commands then
    self:heldColor(result.state.state)
    self:report(result.entity, result.state)
  end
end

--- A SMART light's answer to a poll.
--- @param response table get_device_info's answer.
--- @param asked integer The commands made when the poll went out.
function TplinkLightAdapter:smartPolled(response, asked)
  if tointeger(Select(response, "error_code")) ~= 0 then
    log:warn("get_device_info failed: %s", response)
    self:missed()
    return
  end
  --- @type TplinkSmartInfo
  local info = Select(response, "result") or {}
  if not self.follower:accepts(info.mac) then
    self:another()
    return
  end
  self:answered()
  -- A light that is back may be back with other fades of its own.
  self.ownFades.due = self.ownFades.due or not self.connected
  self.connected = true
  if asked == self.commands then
    local moved = self:smartRead(info)
    for field, value in pairs(self:heldColor(toboolean(info.device_on)) or {}) do
      info[field] = value
    end
    self:report(SmartBulb.entity(info), SmartBulb.state(info), moved)
  end
end

--- A poll that failed on its transport.
--- @param what string The request, for the log.
--- @param err TplinkLinkError
function TplinkLightAdapter:pollFailed(what, err)
  log:warn("%s failed: %s", what, Select(err, "error") or err)
  self:missed()
  if Select(err, "code") == 403 then
    UpdateProperty("Driver Status", "Disconnected: " .. Select(err, "error"))
  end
end

--- Send a light command to the direct-mode light now.
--- @param opts TplinkLightOpts
--- @return boolean sent false when the command names nothing to send.
function TplinkLightAdapter:sendNow(opts)
  if self.schema == nil then
    log:debug("Light command dropped: the light is not connected")
    return false
  end
  if self.schema == "iot" and self.bulb ~= nil then
    self:fly(
      self.bulb:execute(opts, function(params, on)
        self:holdColor(params, on)
      end),
      function() end,
      function(err)
        -- Command failures are logged only; the poll loop decides connectivity.
        log:error("IOT bulb command failed: %s", Select(err, "error") or err)
      end
    )
    return true
  end

  -- A color for a light that is off is held, and added to the next on.
  local params = SmartBulb.params(opts, self.entity)
  -- No on with it: the light is off, or is being turned off.
  self:holdColor(params, params.device_on)
  if IsEmpty(params) then
    return false
  end
  self.smartHeld = self.smartHeld or {}
  for field, value in pairs(params) do
    self.smartHeld[field] = value
  end
  self:fly(self.link.smart:request({ method = "set_device_info", params = params }), function(response)
    local code = tointeger(Select(response, "error_code")) or -1
    if code ~= 0 then
      log:error("set_device_info failed: %s", response)
    end
  end, function(err)
    log:error("set_device_info failed: %s", Select(err, "error") or err)
    self:disconnect()
  end)
  return true
end

--- A fade's length in milliseconds, 0 for one that is off or not there.
--- @param state TplinkFadeSwitch?
--- @param ms integer? The length, for a fade the light names none for.
--- @return integer
local function fadeLength(state, ms)
  return type(state) == "table" and toboolean(state.enable) and (ms or (tointeger(state.duration) or 0) * 1000) or 0
end

--- Read the light's own fades and switch on each that is off, at the length it
--- has, which is the owner's. Then the proxy is told the rate that is fixed.
function TplinkLightAdapter:readOwnFades()
  self:fly(self.link.smart:request({ method = "get_on_off_gradually_info", params = {} }), function(response)
    self:ownFadesAnswered(response)
  end, function(err)
    self:ownFadesFailed(err)
  end)
end

--- The light's own fades could not be read or switched on: the proxy is told
--- the rates as they are.
--- @param err TplinkLinkError|table
function TplinkLightAdapter:ownFadesFailed(err)
  log:warn("The light's own fades could not be read or switched on: %s", Select(err, "error") or err)
  self.host:fadesRead()
end

--- The light's answer to get_on_off_gradually_info.
--- @param response table
function TplinkLightAdapter:ownFadesAnswered(response)
  local info = Select(response, "result")
  if tointeger(Select(response, "error_code")) ~= 0 or type(info) ~= "table" then
    self:ownFadesFailed(response)
    return
  end
  -- An older light answers with one switch for all its fades and no length
  -- for them: it is switched on as the others are, and told as no fade.
  if info.enable ~= nil then
    self:switchOn({ names = { "all" }, info = { all = info }, one = true }, 1)
  else
    self:switchOn({ names = { "on_state", "off_state", "change_state" }, info = info, one = false }, 1)
  end
end

--- Switch on the fades that are off, from the `i`th, a request each, and then
--- take them all as they are.
--- @param read TplinkFadeRead
--- @param i integer
function TplinkLightAdapter:switchOn(read, i)
  local name = read.names[i]
  local state = read.info[name]
  if self.fades ~= "Light" then
    return
  end
  if name == nil then
    self.ownFades = {
      on = fadeLength(read.info.on_state),
      off = fadeLength(read.info.off_state),
      change = fadeLength(read.info.change_state, OWN_CHANGE_MS),
    }
    self.host:fadesRead()
  elseif type(state) ~= "table" or toboolean(state.enable) then
    self:switchOn(read, i + 1)
  else
    local params = read.one and { enable = true } or { [name] = { enable = true, duration = state.duration } }
    self:fly(self.link.smart:request({ method = "set_on_off_gradually_info", params = params }), function(answer)
      self:switchedOn(read, i, answer)
    end, function(err)
      self:ownFadesFailed(err)
    end)
  end
end

--- The light's answer to switching on its `i`th fade.
--- @param read TplinkFadeRead
--- @param i integer
--- @param answer table
function TplinkLightAdapter:switchedOn(read, i, answer)
  local state = read.info[read.names[i]]
  state.enable = tointeger(Select(answer, "error_code")) == 0
  if not state.enable then
    self:ownFadesFailed(answer)
  end
  self:switchOn(read, i + 1)
end

--- Take the Fades property's choice, on a light that has one: the light's own
--- fades are due to be read.
--- @param fades TplinkLightFades
function TplinkLightAdapter:setFades(fades)
  self.fades = fades
  self.ownFades.due = true
end

--- The light's own fades first when due, then the command, then the poll, which
--- so reads the light after it, then a fade's next step.
function TplinkLightAdapter:next()
  -- An answer's handler may have put a request of its own in flight.
  if self.busy then
    return
  end
  if self.ownFades.due then
    self.ownFades.due = false
    if self.fades == "Light" then
      self:readOwnFades()
      return
    end
  end
  local waiting = self.waiting
  self.waiting = nil
  if waiting ~= nil and self:sendNow(waiting) then
    return
  end
  if self.pollWaiting then
    self.pollWaiting = false
    self:poll()
  end
  self.host:step()
end

--- A command from Control4. What the light held before it may be another
--- hand's, older than the command: a poll after it is news only against what
--- it holds since.
function TplinkLightAdapter:commanded()
  if self.fades then
    self.smartHeld = nil
  end
end

--- Send a light command to the direct-mode light, or hold it while a request
--- is in flight. Commands held together go out as one, merged field by field
--- with the later value winning; a later color replaces an earlier one whole.
--- @param opts TplinkLightOpts
function TplinkLightAdapter:execute(opts)
  -- A color for a SMART light that is off is no off: a light turned on since
  -- is left on. It names no state here, so an off it waits with is still one.
  if self.schema ~= "iot" and opts.state == false and (opts.has_rgb or opts.has_color_temperature) then
    opts.has_state, opts.state = nil, nil
  end
  self.commands = self.commands + 1
  if not self.busy then
    self:sendNow(opts)
    -- A command that sent nothing has no answer to bring a fade's next step.
    self.host:step()
    return
  end
  if self.waiting == nil then
    self.waiting = opts
    return
  end
  if opts.has_rgb or opts.has_color_temperature then
    for _, field in ipairs(TplinkLightAdapter.COLOR_FIELDS) do
      self.waiting[field] = nil
    end
  end
  for field, value in pairs(opts) do
    self.waiting[field] = value
  end
end

--- Forget the light's MAC: an address set by hand may be another device's, as
--- a replacement's is, and whichever answers there is followed from now on.
function TplinkLightAdapter:forgetDevice()
  self.follower:forget()
end

--- Discard every established session, for the next start to detect afresh.
function TplinkLightAdapter:resetLinks()
  self.link.klap:reset()
  self.link.klapV1:reset()
  self.link.tpap:reset()
  self.link.legacy:reset()
end

--- Stop reaching the light: no poll, and a probe or an answer that comes in
--- after does nothing.
function TplinkLightAdapter:stop()
  self.generation = self.generation + 1
  self:stopPolling()
  self.detecting, self.connected, self.busy = false, false, false
  -- A search for the light holds a listener open.
  self.follower:stop()
end

return TplinkLightAdapter
