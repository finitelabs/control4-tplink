--- The TP-Link light's connection, and its adapter for the light library, in
--- one of two ways:
---   Outlet: bound to a TP-Link Outlet output, the outlet reports the lamp's
---     state (UPDATE_STATE) and takes its commands (ENTITY_COMMAND).
---   Direct: the IP Address and TP-Link credential properties point at a Kasa
---     or Tapo light. light_probe.lua finds which protocol and schema it
---     answers; from then on it is polled, and serves one request at a time.
--- Each light command goes out on that transport, and what the light reports
--- goes to the host, the light driver, as the light's facts and its state.

local log = require("lib.logging")
local constants = require("constants")
local Color = require("lib.light.color")
local Follower = require("tplink.discovery").Follower
local Klap = require("tplink.klap")
local Legacy = require("tplink.legacy")
local Tpap = require("tplink.tpap")
local SmartBulb = require("tplink.smartbulb")
local Hsv = require("tplink.hsv")
local TplinkLightProbe = require("tplink.light_probe")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("lib.utils")

local ColorMode = constants.LightColorMode

local DIRECT_POLL_TIMER = "DirectPoll"

--- How long a request in flight is waited for, in milliseconds: past the
--- transports' own timeouts, 10 s for a KLAP post and 5 s on the legacy port.
--- @type number
local DIRECT_ANSWER_MS = 15000

local DIRECT_ANSWER_TIMER = "DirectAnswer"

--- The longest fade the driver walks, in milliseconds: a day, the longest rate
--- Control4's own bulbs take.
--- @type integer
local WALK_MAX_MS = 86400000

--- How long a light takes over its own fade between two states while it is
--- on, in milliseconds. It reports no length for it: measured on a Tapo strip.
--- @type number
local OWN_CHANGE_MS = 1000

--- The color temperature range of a light that reports none, in mireds.
local DEFAULT_MIN_MIREDS = 153
local DEFAULT_MAX_MIREDS = 500

--- Driver Status while the light is searched for on the network.
local LOOKING = "Looking for the device on the network..."

--- @type table<integer, boolean>
local MODES_WITH_BRIGHTNESS = {
  [ColorMode.COLOR_MODE_LEGACY_BRIGHTNESS] = true,
  [ColorMode.COLOR_MODE_BRIGHTNESS] = true,
  [ColorMode.COLOR_MODE_WHITE] = true,
  [ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<integer, boolean>
local MODES_WITH_RGB = {
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<integer, boolean>
local MODES_WITH_CCT = {
  [ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- The color mode a command names for each kind of color, the most specific
--- first: a light is unambiguous in a mode with one purpose.
--- @type table<string, integer[]>
local COLOR_MODE_ORDER = {
  cct = {
    ColorMode.COLOR_MODE_COLD_WARM_WHITE,
    ColorMode.COLOR_MODE_COLOR_TEMPERATURE,
    ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE,
    ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE,
  },
  rgb = {
    ColorMode.COLOR_MODE_RGB,
    ColorMode.COLOR_MODE_RGB_WHITE,
    ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE,
    ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE,
  },
}

--- The direct schema found at the light: "smart" (get_device_info and
--- set_device_info, mapped by smartbulb.lua) or "iot" (sysinfo and
--- transition_light_state, mapped by an IotBulb).
--- @alias TplinkLightSchema "smart"|"iot"

--- Who makes a SMART light's fades, from the Fades property: "Driver" in
--- steps, or "Light" at the light's own lengths.
--- @alias TplinkLightFades "Driver"|"Light"

--- What the connection tells the light driver; the driver implements each.
--- @class TplinkLightHost
--- @field declare fun(self: TplinkLightHost, device: LightDevice) The facts of the light connected.
--- @field report fun(self: TplinkLightHost, report: LightReport) The light's state as it reports it.
--- @field lost fun(self: TplinkLightHost) The light stopped answering.
--- @field restart fun(self: TplinkLightHost, retry: boolean?) Start the connection again. retry: the poll timer trying again after no light was found.

--- The direct-mode transports.
--- @class TplinkLightLink
--- @field klap Klap KLAP v2 hashing: SMART-firmware devices and KL-series bulbs on newer KLAP firmware.
--- @field klapV1 Klap KLAP v1 hashing: KL-series bulbs whose KLAP firmware uses the MD5-based hashes.
--- @field legacy Legacy Port 9999: KL-series bulbs on original firmware.
--- @field tpap Tpap TPAP: a light whose account has Third-Party Compatibility off.
--- @field smart Klap|Tpap The session SMART-schema requests go through.

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

--- A light's answer, kept until it can be told.
--- @class TplinkLightAnswer
--- @field entity TplinkLightEntity
--- @field state TplinkLightState

--- What waits for the request in flight: a command, or a poll.
--- @alias TplinkLightQueued TplinkLightOpts|"poll"

--- @class TplinkLightAdapter : LightAdapter
--- @field host TplinkLightHost
--- @field outletBinding integer The binding to a TP-Link Outlet output.
--- @field link TplinkLightLink
--- @field follower Follower Follows the light to a new address by its MAC.
--- @field statusBefore string? Driver Status before a search for the light.
--- @field misses integer Polls in a row the light has not answered.
--- @field schema TplinkLightSchema?
--- @field bulb IotBulb? The IOT schema's mapping, for "iot".
--- @field transport string? "Outlet", "SMART", "KLAP", "TPAP" or "Legacy", for Driver Status.
--- @field connected boolean The light has reported since the start.
--- @field generation integer Counts the starts: an attempt, and the answer to a poll or a command, does nothing once it has moved on.
--- @field detecting boolean A start is still probing. The poll timer's retry waits for it.
--- @field busy boolean A request is in flight. The rest wait for it in queue.
--- @field queue TplinkLightQueued[] What waits for the request in flight, in the order it came.
--- @field pollPassed boolean A command has gone ahead of the poll waiting.
--- @field entity TplinkLightEntity? What the light last reported it can do.
--- @field first TplinkLightAnswer? A SMART light's first answer, waiting for its own fades to be read.
--- @field fades TplinkLightFades? Who makes a SMART light's fades; nil on any other.
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
  self.queue = {}
  self.pollPassed = false
  self.ownFades = {}
  return self
end

---------------------------------------------------------------------------
-- The light's facts and its reports
---------------------------------------------------------------------------

--- Whether a light lists a color mode of a set.
--- @param entity TplinkLightEntity?
--- @param modes table<integer, boolean>
--- @return boolean
local function lists(entity, modes)
  local listed = Select(entity, "supported_color_modes")
  if not IsList(listed) then
    return false
  end
  for _, mode in ipairs(listed) do
    if modes[mode] then
      return true
    end
  end
  return false
end

--- The color mode a command names for a kind of color, or nil for a light
--- that lists none for it.
--- @param entity TplinkLightEntity?
--- @param kind "cct"|"rgb"
--- @return integer?
local function pickColorMode(entity, kind)
  for _, mode in ipairs(COLOR_MODE_ORDER[kind]) do
    if lists(entity, { [mode] = true }) then
      return mode
    end
  end
  return nil
end

--- How the light moves: a Kasa light fades over the time a command carries; a
--- SMART light takes none, so the Fades property says who makes its fades.
--- @return LightFade|nil
function TplinkLightAdapter:fade()
  if self.schema == "iot" then
    return { kind = "device", curve = "linear", maxMs = 60000 }
  end
  if self.fades == "Driver" then
    return { kind = "walk", stepMs = 100, maxMs = WALK_MAX_MS }
  end
  if self.fades == "Light" then
    local own = self.ownFades
    return { kind = "own", own = { onMs = own.on or 0, offMs = own.off or 0, changeMs = own.change or 0 } }
  end
  return nil
end

--- The facts of the light connected, as its last report names them.
--- @return LightDevice
function TplinkLightAdapter:device()
  local entity = self.entity
  local cct = nil
  if lists(entity, MODES_WITH_CCT) then
    local minMireds = tonumber(Select(entity, "min_mireds")) or 0
    local maxMireds = tonumber(Select(entity, "max_mireds")) or 0
    cct = {
      minK = Color.miredsToKelvin(maxMireds > 0 and maxMireds or DEFAULT_MAX_MIREDS),
      maxK = Color.miredsToKelvin(minMireds > 0 and minMireds or DEFAULT_MIN_MIREDS),
    }
  end
  return {
    dims = lists(entity, MODES_WITH_BRIGHTNESS),
    color = lists(entity, MODES_WITH_RGB),
    cct = cct,
    -- A light drops a color sent while it is off.
    colorWhileOff = "hold",
    levelSteps = 100,
    fade = self:fade(),
    feedback = { shows = "target", waitMs = 2000, refresh = true },
  }
end

--- The color a light reports, in the mode it is in.
--- @param state TplinkLightState
--- @return LightColor|nil
local function reportedColor(state)
  local mode = tointeger(Select(state, "color_mode"))
  if mode and MODES_WITH_CCT[mode] then
    local kelvin = Color.miredsToKelvin(tonumber(Select(state, "color_temperature")))
    if kelvin > 0 then
      local x, y = Color.kelvinToXY(kelvin)
      return { x = x, y = y, mode = "cct", kelvin = kelvin }
    end
  elseif mode and MODES_WITH_RGB[mode] then
    local r = tonumber(Select(state, "red")) or 0
    local g = tonumber(Select(state, "green")) or 0
    local b = tonumber(Select(state, "blue")) or 0
    if r > 0 or g > 0 or b > 0 then
      local h, s = Hsv.fromRGB(r, g, b)
      local x, y = C4:ColorHSVtoXY(h, s, 100)
      return { x = x, y = y, mode = "xy" }
    end
  end
  return nil
end

--- A light's state as a report. Off, a light holds the level and color it
--- comes on in.
--- @param entity TplinkLightEntity
--- @param state TplinkLightState
--- @return LightReport
local function report(entity, state)
  local on = Select(state, "state") == true
  --- @type LightReport
  local out = { kind = "push", on = on }
  if lists(entity, MODES_WITH_BRIGHTNESS) then
    out.level = tofinite(Select(state, "brightness")) or (on and 1 or nil)
  end
  if lists(entity, MODES_WITH_RGB) or lists(entity, MODES_WITH_CCT) then
    out.color = reportedColor(state)
  end
  return out
end

--- Tell the host the light's facts and its state. The first since the start
--- shows the light connected.
--- @param entity TplinkLightEntity
--- @param state TplinkLightState
function TplinkLightAdapter:tell(entity, state)
  self.entity = entity
  if not self.connected then
    self.connected = true
    UpdateProperty("Driver Status", "Connected (" .. tostring(self.transport) .. ")")
  end
  self.host:declare(self:device())
  self.host:report(report(entity, state))
end

---------------------------------------------------------------------------
-- The light library's adapter
---------------------------------------------------------------------------

--- A color as a light command's fields: a white as its color temperature on a
--- light that has one, any other as RGB on a light with color.
--- @param entity TplinkLightEntity?
--- @param color LightColor
--- @return table<string, boolean|number>|nil
local function colorFields(entity, color)
  local fields, mode
  if color.mode == "cct" and lists(entity, MODES_WITH_CCT) then
    fields = {
      has_color_temperature = true,
      color_temperature = Color.kelvinToMireds(color.kelvin or Color.kelvin(color.x, color.y)),
    }
    mode = pickColorMode(entity, "cct")
  elseif lists(entity, MODES_WITH_RGB) then
    local h, s = C4:ColorXYtoHSV(color.x, color.y)
    local r, g, b = Hsv.toRGB(h or 0, s or 100, 100)
    fields = { has_rgb = true, red = r, green = g, blue = b }
    mode = pickColorMode(entity, "rgb")
  else
    return nil
  end
  if mode then
    fields.has_color_mode, fields.color_mode = true, mode
  end
  return fields
end

--- A light command in the shape both transports take.
--- @param entity TplinkLightEntity?
--- @param cmd LightCommand
--- @return TplinkLightOpts
local function commandOpts(entity, cmd)
  --- @type TplinkLightOpts
  local opts = { has_state = true, state = cmd.on }
  if not lists(entity, MODES_WITH_BRIGHTNESS) then
    return opts
  end
  if cmd.setsLevel then
    opts.has_brightness, opts.brightness = true, cmd.on and cmd.level or 0
  end
  if cmd.setsColor and cmd.color then
    for field, value in pairs(colorFields(entity, cmd.color) or {}) do
      opts[field] = value
    end
  end
  opts.has_transition_length, opts.transition_length = true, cmd.transitionMs
  return opts
end

--- Put one command on the light's transport.
--- @param cmd LightCommand
--- @return LightRest|nil
function TplinkLightAdapter:send(cmd)
  local opts = commandOpts(self.entity, cmd)
  log:debug("Light command: %s", opts)
  if self.transport == "Outlet" then
    self:sendOutlet(opts)
  else
    self:execute(opts)
  end
  return nil
end

--- Ask the light for its whole state: the outlet re-pushes it, and a direct
--- light is polled. One still being found answers when it is.
function TplinkLightAdapter:refresh()
  if self.transport == "Outlet" then
    SendToProxy(self.outletBinding, "REFRESH_STATE", {}, "NOTIFY")
  elseif self.schema ~= nil then
    self:poll()
  end
end

--- The light has no device page.
--- @param _shown LightShown
function TplinkLightAdapter:show(_shown) end

---------------------------------------------------------------------------
-- The connection
---------------------------------------------------------------------------

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
--- bound outlet wins; the network properties are hidden while bound. The
--- light is asked for its state by refresh().
--- @param retry boolean? The poll timer trying again after no light was found.
function TplinkLightAdapter:start(retry)
  self:stopPolling()
  self.generation = self.generation + 1
  self.detecting = false
  self.connected = false
  self.transport = nil
  self.schema = nil
  self.bulb = nil
  self.entity = nil
  self.first = nil
  -- The request in flight and what waited were for the connection as it was.
  self.busy = false
  self.queue = {}
  self.pollPassed = false
  self.fades = nil
  self.ownFades = {}
  C4:SetPropertyAttribs("Fades", constants.HIDE_PROPERTY)

  if self:bound() then
    self.transport = "Outlet"
    -- The outlet reaches the light: there is no address to follow.
    self.follower:stop()
    setNetworkPropertiesAttribs(constants.HIDE_PROPERTY)
    return
  end

  setNetworkPropertiesAttribs(constants.SHOW_PROPERTY)

  local ip = Properties["IP Address"] or ""
  if IsEmpty(ip) then
    self.follower:stop()
    self:noLight("Bind to an outlet or set the IP Address property")
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

--- End a start with no light to reach. The light stays offline, as the start
--- told it.
--- @param status string
function TplinkLightAdapter:noLight(status)
  UpdateProperty("Driver Status", status)
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
  -- A light on the SMART schema takes no fade time from a command, so who
  -- makes its fades is the installer's choice.
  if schema == "smart" then
    self.fades = Properties["Fades"] or "Driver"
    self.ownFades.due = true
    C4:SetPropertyAttribs("Fades", constants.SHOW_PROPERTY)
  end
  log:info("Using %s transport for direct control", name)
  if self.fades == "Light" then
    -- Its first answer waits for its own fades, so it is declared with them.
    self.first = { entity = entity, state = state }
  else
    self:tell(entity, state)
  end
  self:next()
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
  self:tell(entity, state)
end

--- Send a light command to the bound outlet.
--- @param opts TplinkLightOpts
function TplinkLightAdapter:sendOutlet(opts)
  SendToProxy(self.outletBinding, "ENTITY_COMMAND", {
    body = SerializeSafe(opts),
  }, "NOTIFY")
end

--- The light is gone: it reads off.
function TplinkLightAdapter:lost()
  self.connected = false
  self.entity = nil
  UpdateProperty("Driver Status", "Disconnected")
  self.host:lost()
end

--- The direct light no longer answers.
function TplinkLightAdapter:disconnect()
  if self.connected then
    self:lost()
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

--- Poll the direct-mode light, and tell the host what it holds.
function TplinkLightAdapter:poll()
  if self.busy then
    for _, queued in ipairs(self.queue) do
      if queued == "poll" then
        return
      end
    end
    self.queue[#self.queue + 1] = "poll"
    return
  end

  if self.schema == "iot" and self.bulb ~= nil then
    self:fly(self.bulb:poll(), function(result)
      self:iotPolled(result)
    end, function(err)
      self:pollFailed("IOT bulb poll", err)
    end)
    return
  end

  self:fly(self.link.smart:request({ method = "get_device_info", params = {} }), function(response)
    self:smartPolled(response)
  end, function(err)
    self:pollFailed("get_device_info", err)
  end)
end

--- An IOT light's answer to a poll.
--- @param result TplinkIotPoll
function TplinkLightAdapter:iotPolled(result)
  if not self.follower:accepts(result.mac) then
    self:another()
    return
  end
  self:answered()
  self:tell(result.entity, result.state)
end

--- A SMART light's answer to a poll.
--- @param response table get_device_info's answer.
function TplinkLightAdapter:smartPolled(response)
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
  self:tell(SmartBulb.entity(info), SmartBulb.state(info))
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
    self:fly(self.bulb:execute(opts), function() end, function(err)
      -- Command failures are logged only; the poll loop decides connectivity.
      log:error("IOT bulb command failed: %s", Select(err, "error") or err)
    end)
    return true
  end

  local params = SmartBulb.params(opts, self.entity)
  if IsEmpty(params) then
    return false
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
--- has, which is the owner's. Then the light is declared with them.
function TplinkLightAdapter:readOwnFades()
  self:fly(self.link.smart:request({ method = "get_on_off_gradually_info", params = {} }), function(response)
    self:ownFadesAnswered(response)
  end, function(err)
    self:ownFadesFailed(err)
  end)
end

--- The light's own fades are read, or could not be: a first answer that
--- waited for them is told now, and otherwise the light is declared again.
function TplinkLightAdapter:fadesRead()
  local first = self.first
  self.first = nil
  if first then
    self:tell(first.entity, first.state)
  else
    self.host:declare(self:device())
  end
end

--- The light's own fades could not be read or switched on: it is declared
--- with them as they are.
--- @param err TplinkLinkError|table
function TplinkLightAdapter:ownFadesFailed(err)
  log:warn("The light's own fades could not be read or switched on: %s", Select(err, "error") or err)
  self:fadesRead()
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
  -- for them: it is switched on as the others are, and taken as no fade.
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
    self:fadesRead()
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

--- Take the Fades property's choice, on a light that has one. For Light, the
--- light's own fades are read before it is declared with them.
--- @param fades TplinkLightFades
function TplinkLightAdapter:setFades(fades)
  if self.fades == nil or self.fades == fades then
    return
  end
  self.fades = fades
  self.ownFades.due = true
  if fades == "Driver" then
    self:fadesRead()
  end
  self:next()
end

--- The light's own fades first when due, then what waits, in the order it came,
--- but for a command behind a poll, which goes ahead of it once: the poll then
--- reads the light after it, and waits for one command at most.
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
  while #self.queue > 0 do
    local queued
    if self.queue[1] == "poll" and self.queue[2] ~= nil and not self.pollPassed then
      self.pollPassed = true
      queued = table.remove(self.queue, 2)
    else
      queued = table.remove(self.queue, 1)
    end
    if queued == "poll" then
      self.pollPassed = false
      self:poll()
      return
    end
    if self:sendNow(queued) then
      return
    end
  end
end

--- @param opts TplinkLightOpts
--- @return boolean
local function hasColor(opts)
  return opts.has_rgb or opts.has_color_temperature or false
end

--- Send a light command to the direct-mode light, or queue it while a request
--- is in flight. One queued behind a command merges into it, field by field
--- with the later value winning, and a later color replaces an earlier one
--- whole. An off waits behind a color instead: the light drops a color sent
--- with an off.
--- @param opts TplinkLightOpts
function TplinkLightAdapter:execute(opts)
  -- An answer's handler runs before the queue moves on, so one sent from it waits its turn.
  if not self.busy and #self.queue == 0 then
    self:sendNow(opts)
    return
  end
  local last = self.queue[#self.queue]
  if type(last) ~= "table" or (opts.state == false and last.state ~= false and hasColor(last)) then
    self.queue[#self.queue + 1] = opts
    return
  end
  if hasColor(opts) then
    for _, field in ipairs(TplinkLightAdapter.COLOR_FIELDS) do
      last[field] = nil
    end
  end
  for field, value in pairs(opts) do
    last[field] = value
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
  self.first = nil
  -- A search for the light holds a listener open.
  self.follower:stop()
end

return TplinkLightAdapter
