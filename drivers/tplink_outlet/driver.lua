--#ifdef DRIVERCENTRAL
DC_PID = 976
DC_X = nil
DC_FILENAME = "tplink_outlet.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-tplink"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
local driverFilenames = require("lib.driver-filenames")
--#endif
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
local constants = require("constants")
local bindings = require("lib.bindings")
local values = require("lib.values")
local Klap = require("tplink.klap")
local Legacy = require("tplink.legacy")
local Smart = require("tplink.smart")
local Tpap = require("tplink.tpap")
local Discovery = require("tplink.discovery")

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

--- Driver initialization flag.
--- @type boolean
local gInitialized = false

--- KLAP transport to the device (v2 hashing: SMART-firmware devices).
--- @type Klap
local klap = Klap:new()

--- KLAP transport with v1 hashing (legacy Kasa devices updated to KLAP firmware).
--- @type Klap
local klapV1 = Klap:new({ authVersion = 1 })

--- SMART-schema adapter over the KLAP v2 transport (Kasa EP25 v2.6/KP125M, Tapo plugs).
--- @type Smart
local smart = Smart:new(klap)

--- Legacy (port 9999) transport to the device.
--- @type Legacy
local legacy = Legacy:new()

--- TPAP transport, for a device whose account has Third-Party Compatibility off.
--- @type Tpap
local tpap = Tpap:new()

--- SMART-schema adapter over the TPAP transport.
--- @type Smart
local smartTpap = Smart:new(tpap)

--- The active transport, set by connect-time detection.
--- @type Klap|Legacy|Smart|Tpap|nil
local transport = nil

--- Human-readable name of the active transport, for Driver Status.
--- @type string?
local transportName = nil

--- @class Output
--- @field childId string? The device-side child id (nil for single-outlet devices).
--- @field state boolean? Last known relay state.

--- Last known state per output, keyed 1..MAX_OUTPUTS.
--- @type table<number, Output>
local outputs = {}

--- Number of outputs the device reports (1 for plain plugs, 6 for HS300).
--- @type number
local outputCount = 0

--- Whether the last sysinfo poll succeeded (drives Connected/Disconnected events).
--- @type boolean
local deviceOnline = false

--- Whether a sysinfo poll is currently in flight (avoids stacking timers).
--- @type boolean
local sysinfoInFlight = false

--- Whether an energy poll is currently in flight.
--- @type boolean
local energyInFlight = false

--- Counts reconnect(): a probe, a poll or a write answered after the next one
--- began does nothing.
--- @type integer
local connectGeneration = 0

--- Whether a connect attempt is still probing. The poll timer's retry waits
--- for it: a start would replace it before it had found or failed to find.
--- @type boolean
local detecting = false

--- Properties that stay hidden until the device reports data for them.
--- @type string[]
local DEVICE_PROPERTIES = { "Device Information", "Model", "Device Name", "MAC Address", "Firmware", "WiFi RSSI" }

--#ifndef DRIVERCENTRAL
--- Get all device IDs for instances of the TP-Link driver suite (outlet and
--- light), sorted ascending. The suite shares one GitHub updater; the
--- instance with the lowest id is the update leader regardless of type.
--- @return integer[]
local function getDriverIds()
  local ids = {}
  for _, filename in ipairs(driverFilenames) do
    for id, _ in pairs(C4:GetDevicesByC4iName(filename) or {}) do
      table.insert(ids, tointeger(id))
    end
  end
  table.sort(ids)
  return ids
end
--#endif

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Update the Driver Status property.
--- @param status string
local function updateDriverStatus(status)
  UpdateProperty("Driver Status", status)
end

--- A continuation of the connect attempt `generation`, which does nothing once
--- reconnect() has begun another.
--- @param generation integer
--- @param continuation function
--- @return function live
local function live(generation, continuation)
  return function(...)
    if generation == connectGeneration then
      return continuation(...)
    end
  end
end

--- Follows the device to a new address; defined with the transport detection.
local follower

--- Mark the device online/offline, firing Connected/Disconnected events on change.
--- @param online boolean
--- @param reason string? Status detail shown when offline.
local function setDeviceOnline(online, reason)
  if online ~= deviceOnline then
    deviceOnline = online
    C4:FireEventByID(online and constants.EVENT_CONNECTED or constants.EVENT_DISCONNECTED)
    log:info("Device is %s", online and "online" or "offline")
  end
  if online then
    follower:found()
    updateDriverStatus(transportName and ("Connected (" .. transportName .. ")") or "Connected")
  else
    updateDriverStatus(not IsEmpty(reason) and ("Disconnected: " .. reason) or "Disconnected")
    -- The first power reading after a reconnect is the device's as it is, not a change.
    for _, output in pairs(outputs) do
      output.inUse, output.heldSince = nil, nil
    end
    for _, binding in pairs(bindings:getDynamicBindings("light")) do
      SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
    end
  end
end

--- Forward declared; defined in the Control section.
local setOutput, toggleOutput

--- Tell a relay binding an output's known state without firing the bound
--- driver's programming. Sends nothing while the state is unknown.
--- @param idBinding integer
--- @param n number Output number (1-based).
local function reportRelayState(idBinding, n)
  local state = Select(outputs, n, "state")
  if state ~= nil then
    SendToProxy(idBinding, state and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end

--- Get or create the dynamic relay binding for an output and wire its handlers.
--- @param n number Output number (1-based).
--- @return integer|nil bindingId
local function ensureRelayBinding(n)
  local binding =
    bindings:getOrAddDynamicBinding("relay", "output_" .. n, "CONTROL", true, "Output " .. n .. " Relay", "RELAY")
  if binding == nil then
    return nil
  end

  RFP[binding.bindingId] = function(idBinding, strCommand, tParams)
    log:trace("RFP relay output=%s strCommand=%s", n, strCommand)
    if strCommand == "ON" or strCommand == "CLOSE" then
      setOutput(n, true)
    elseif strCommand == "OFF" or strCommand == "OPEN" then
      setOutput(n, false)
    elseif strCommand == "TOGGLE" then
      toggleOutput(n)
    elseif strCommand == "TRIGGER" then
      setOutput(n, true)
      local pulseTime = tonumber_locale(tParams.TIME) or 0
      if pulseTime > 0 then
        SetTimer("FinishPulse" .. n, pulseTime, function()
          setOutput(n, false)
        end)
      end
    elseif strCommand == "GET_STATE" then
      reportRelayState(idBinding, n)
    end
  end

  OBC[binding.bindingId] = function(idBinding, _, bIsBound)
    if bIsBound then
      reportRelayState(idBinding, n)
    end
  end

  return binding.bindingId
end

--- Push the current state of an output to a bound tplink_light driver.
--- Uses the TPLINK_LIGHT binding protocol: UPDATE_STATE carries a serialized
--- on/off entity and state in the same shape the light driver's direct mode
--- synthesizes for real light devices.
--- @param n number Output number (1-based).
local function pushLightState(n)
  local binding = bindings:getDynamicBinding("light", "output_" .. n)
  if binding == nil or outputs[n] == nil or outputs[n].state == nil then
    return
  end
  SendToProxy(binding.bindingId, "UPDATE_STATE", {
    entity = SerializeSafe({ supported_color_modes = { constants.LightColorMode.COLOR_MODE_ON_OFF } }),
    state = SerializeSafe({ state = outputs[n].state }),
  }, "NOTIFY")
end

--- Get or create the dynamic light binding for an output and wire its handlers.
--- @param n number Output number (1-based).
local function ensureLightBinding(n)
  local binding = bindings:getOrAddDynamicBinding(
    "light",
    "output_" .. n,
    "CONTROL",
    true,
    "Output " .. n .. " Light",
    "TPLINK_LIGHT"
  )
  if binding == nil then
    return
  end

  RFP[binding.bindingId] = function(_, strCommand, tParams)
    log:trace("RFP light output=%s strCommand=%s", n, strCommand)
    if strCommand == "REFRESH_STATE" then
      pushLightState(n)
    elseif strCommand == "ENTITY_COMMAND" then
      local opts = DeserializeSafe(Select(tParams, "body"))
      if type(opts) == "table" and opts.has_state then
        setOutput(n, opts.state and true or false)
      end
    end
  end

  OBC[binding.bindingId] = function(_, _, bIsBound)
    if bIsBound then
      pushLightState(n)
    end
  end
end

--- How long after a keypad button's press its other half is ignored: a tap
--- sends DO_PUSH then DO_CLICK, and some senders send only one of them.
local BUTTON_LINK_COALESCE_MS = 500

--- Keypad links inside their coalescing window, by binding id. Kept outside the
--- handlers, which each sysinfo poll wires again.
--- @type table<integer, boolean>
local buttonCoalescing = {}

--- Each output's keypad links, by the key of their binding.
local BUTTON_LINKS = {
  { key = "on", name = "On" },
  { key = "off", name = "Off" },
  { key = "toggle", name = "Toggle" },
}

--- Tell a keypad link its LED state: On and Toggle light while the output is
--- on, Off while it is off. Sends nothing while the state is unknown.
--- @param idBinding integer
--- @param n number Output number (1-based).
--- @param key string "on", "off" or "toggle".
local function reportButtonLed(idBinding, n, key)
  local state = Select(outputs, n, "state")
  if state ~= nil then
    SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = (key == "off") ~= state }, "NOTIFY", true)
  end
end

--- Tell each of an output's keypad links its LED state.
--- @param n number Output number (1-based).
local function reportButtonLeds(n)
  for _, link in ipairs(BUTTON_LINKS) do
    local binding = bindings:getDynamicBinding("button", "output_" .. n .. "_" .. link.key)
    if binding ~= nil then
      reportButtonLed(binding.bindingId, n, link.key)
    end
  end
end

--- Get or create an output's keypad links and wire their handlers.
--- @param n number Output number (1-based).
local function ensureButtonLinks(n)
  for _, link in ipairs(BUTTON_LINKS) do
    local binding = bindings:getOrAddDynamicBinding(
      "button",
      "output_" .. n .. "_" .. link.key,
      "CONTROL",
      true,
      "Output " .. n .. " " .. link.name .. " Button Link",
      "BUTTON_LINK"
    )
    if binding ~= nil then
      RFP[binding.bindingId] = function(idBinding, strCommand)
        log:trace("RFP button output=%s link=%s strCommand=%s", n, link.key, strCommand)
        if strCommand ~= "DO_PUSH" and strCommand ~= "DO_CLICK" then
          return
        end
        if buttonCoalescing[idBinding] then
          return
        end
        buttonCoalescing[idBinding] = true
        SetTimer("ButtonLinkCoalesce" .. idBinding, BUTTON_LINK_COALESCE_MS, function()
          buttonCoalescing[idBinding] = nil
        end)
        if link.key == "on" then
          setOutput(n, true)
        elseif link.key == "off" then
          setOutput(n, false)
        else
          toggleOutput(n)
        end
      end
      OBC[binding.bindingId] = function(idBinding, _, bIsBound)
        if bIsBound then
          reportButtonLed(idBinding, n, link.key)
        end
      end
    end
  end
end

--- Re-wire RFP/OBC handlers for relay and light bindings restored from persistence.
local function restoreRelayHandlers()
  for key, _ in pairs(bindings:getDynamicBindings("relay")) do
    local n = tointeger(string.match(key, "^output_(%d+)$"))
    if n then
      ensureRelayBinding(n)
      outputs[n] = outputs[n] or {}
    end
  end
  for key, _ in pairs(bindings:getDynamicBindings("light")) do
    local n = tointeger(string.match(key, "^output_(%d+)$"))
    if n then
      ensureLightBinding(n)
      outputs[n] = outputs[n] or {}
    end
  end
  for key, _ in pairs(bindings:getDynamicBindings("button")) do
    local n = tointeger(string.match(key, "^output_(%d+)_"))
    if n then
      ensureButtonLinks(n)
      outputs[n] = outputs[n] or {}
    end
  end
end

--- Apply a new relay state for an output: value, events, relay proxy.
--- @param n number Output number (1-based).
--- @param state boolean New relay state.
local function applyOutputState(n, state)
  local name = "Output " .. n .. " State"
  local changed = values:update(name, state, "BOOL", nil, { [true] = "On", [false] = "Off" })
  outputs[n].state = state

  if changed then
    local binding = bindings:getDynamicBinding("relay", "output_" .. n)
    if binding then
      SendToProxy(binding.bindingId, state and "CLOSED" or "OPENED", {}, "NOTIFY")
    end
    reportButtonLeds(n)
    if gInitialized then
      C4:FireEventByID(state and n or (constants.EVENT_OFF_OFFSET + n))
    end
  end

  -- Always re-sync a bound light, not just on change: a light driver that
  -- restarts requests state before we necessarily have it, and would
  -- otherwise stay disconnected until the next actual state change.
  pushLightState(n)
end

--- Parse a get_sysinfo response body and update all output/device state.
--- @param sysinfo table The `system.get_sysinfo` result.
local function applySysinfo(sysinfo)
  for _, property in ipairs(DEVICE_PROPERTIES) do
    C4:SetPropertyAttribs(property, constants.SHOW_PROPERTY)
  end
  UpdateProperty("Model", tostring(sysinfo.model or ""))
  UpdateProperty("Device Name", tostring(sysinfo.alias or ""))
  UpdateProperty("MAC Address", tostring(sysinfo.mac or ""))
  UpdateProperty("Firmware", tostring(sysinfo.sw_ver or ""))
  UpdateProperty("WiFi RSSI", tostring(sysinfo.rssi or ""))
  C4:SetPropertyAttribs("Outputs", constants.SHOW_PROPERTY)

  local children = sysinfo.children
  if type(children) == "table" and #children > 0 then
    outputCount = math.min(#children, constants.MAX_OUTPUTS)
    for n = 1, outputCount do
      local child = children[n]
      outputs[n] = outputs[n] or {}
      -- Some multi-outlet plugs (e.g. EP40A) report short child ids ("00") in
      -- get_sysinfo but reject them in context.child_ids ("entry not exist");
      -- they require the full deviceId-prefixed id. Others (HS300/KP303) already
      -- report the full id. Prefix with the deviceId only for the short form.
      local childId = tostring(child.id)
      local deviceId = tostring(sysinfo.deviceId or "")
      if deviceId ~= "" and #childId < #deviceId then
        childId = deviceId .. childId
      end
      outputs[n].childId = childId
      ensureRelayBinding(n)
      ensureLightBinding(n)
      ensureButtonLinks(n)
      values:update("Output " .. n .. " Name", tostring(child.alias or ("Output " .. n)), "STRING")
      applyOutputState(n, tointeger(child.state) == 1)
    end
  else
    -- Single-outlet device (HS103/HS110/KP115/...): no children, top-level relay_state.
    outputCount = 1
    outputs[1] = outputs[1] or {}
    outputs[1].childId = nil
    ensureRelayBinding(1)
    ensureLightBinding(1)
    ensureButtonLinks(1)
    values:update("Output 1 Name", tostring(sysinfo.alias or "Output 1"), "STRING")
    applyOutputState(1, tointeger(sysinfo.relay_state) == 1)
  end
end

--- Build the context wrapper for a request against one output.
--- Single-outlet devices take commands without a context.
--- @param n number Output number (1-based).
--- @param request table The inner request (e.g. `{ system = { set_relay_state = { state = 1 } } }`).
--- @return table
local function forOutput(n, request)
  local childId = Select(outputs, n, "childId")
  if childId == nil then
    return request
  end
  local wrapped = { context = { child_ids = { childId } } }
  for k, v in pairs(request) do
    wrapped[k] = v
  end
  return wrapped
end

---------------------------------------------------------------------------
-- Polling
---------------------------------------------------------------------------

--- Forward declarations; defined below with the transport detection logic.
local missedPoll, anotherDevice

--- Polls in a row the device has not answered.
local missedPolls = 0

--- Poll output states and device info via get_sysinfo.
local function pollSysinfo()
  if transport == nil then
    return
  end
  if sysinfoInFlight then
    log:debug("Skipping sysinfo poll; previous poll still in flight")
    return
  end
  sysinfoInFlight = true
  local generation = connectGeneration
  transport:request({ system = { get_sysinfo = {} } }):next(
    live(generation, function(response)
      sysinfoInFlight = false
      local sysinfo = Select(response, "system", "get_sysinfo")
      if type(sysinfo) ~= "table" or tointeger(sysinfo.err_code) ~= 0 then
        log:warn("get_sysinfo failed: %s", response)
        missedPoll("device rejected get_sysinfo")
        return
      end
      if not follower:accepts(sysinfo.mac) then
        anotherDevice()
        return
      end
      missedPolls = 0
      applySysinfo(sysinfo)
      setDeviceOnline(true)
    end),
    live(generation, function(err)
      sysinfoInFlight = false
      log:warn("sysinfo poll failed: %s", Select(err, "error") or err)
      missedPoll(Select(err, "error"))
    end)
  )
end

--- An output's In Use and Idle levels in watts, or nil when both are 0. A
--- level left at 0 takes the other's, and Idle is never above In Use.
--- @param n number Output number (1-based).
--- @return number? above
--- @return number? below
local function powerLevels(n)
  local above = tonumber(Properties["Output " .. n .. " In Use Above (W)"]) or 0
  local below = tonumber(Properties["Output " .. n .. " Idle Below (W)"]) or 0
  if above <= 0 and below <= 0 then
    return nil, nil
  end
  if above <= 0 then
    above = below
  end
  if below <= 0 or below > above then
    below = above
  end
  return above, below
end

--- Apply a power reading to an output's In Use state, firing In Use or Idle
--- when it changes. The first reading after a start, a reconnect or a level
--- change only sets the state.
--- @param n number Output number (1-based).
--- @param watts number
local function applyPower(n, watts)
  local output = outputs[n]
  local above, below = powerLevels(n)
  if above == nil then
    output.inUse, output.heldSince = nil, nil
    return
  end
  local was = output.inUse
  if was == nil then
    output.inUse, output.heldSince = watts > above, nil
    values:update("Output " .. n .. " In Use", output.inUse, "BOOL")
    return
  end
  local crossed
  if was then
    crossed = watts < below
  else
    crossed = watts > above
  end
  if not crossed then
    output.heldSince = nil
    return
  end
  -- Readings come at the energy poll rate, so the event fires with the first one after the hold.
  local now = C4:GetTime()
  output.heldSince = output.heldSince or now
  local holdSeconds = math.max(0, tointeger(Properties["Output " .. n .. " Hold (s)"]) or 0)
  if now - output.heldSince < holdSeconds * ONE_SECOND then
    return
  end
  output.inUse, output.heldSince = not was, nil
  values:update("Output " .. n .. " In Use", output.inUse, "BOOL")
  if gInitialized then
    C4:FireEventByID((output.inUse and constants.EVENT_IN_USE_OFFSET or constants.EVENT_IDLE_OFFSET) + n)
  end
end

--- Poll per-output power usage via emeter get_realtime, one output after another.
local function pollEnergy()
  if transport == nil or energyInFlight or outputCount == 0 or not deviceOnline then
    return
  end
  energyInFlight = true
  local generation = connectGeneration

  local voltageReported = false

  local function pollOutput(n)
    if n > outputCount or transport == nil then
      energyInFlight = false
      return
    end
    transport:request(forOutput(n, { emeter = { get_realtime = {} } })):next(
      live(generation, function(response)
        local realtime = Select(response, "emeter", "get_realtime")
        if type(realtime) == "table" and tointeger(realtime.err_code) == 0 then
          -- Hardware v1 reports floats in base units (power/voltage); v2 reports
          -- integers in milli-units (power_mw/voltage_mv).
          local watts
          if realtime.power_mw ~= nil then
            local milliWatts = tofinite(realtime.power_mw)
            watts = milliWatts and milliWatts / 1000
          else
            watts = tofinite(realtime.power)
          end
          if watts ~= nil then
            values:update("Output " .. n .. " Power", string.format("%.1f", watts), "NUMBER", nil, " W")
            if not outputs[n].levelsShown then
              outputs[n].levelsShown = true
              C4:SetPropertyAttribs("Output " .. n .. " In Use Above (W)", constants.SHOW_PROPERTY)
              C4:SetPropertyAttribs("Output " .. n .. " Idle Below (W)", constants.SHOW_PROPERTY)
              C4:SetPropertyAttribs("Output " .. n .. " Hold (s)", constants.SHOW_PROPERTY)
            end
            applyPower(n, watts)
          end
          local voltage
          if realtime.voltage_mv ~= nil then
            local milliVolts = tofinite(realtime.voltage_mv)
            voltage = milliVolts and milliVolts / 1000
          else
            voltage = tofinite(realtime.voltage)
          end
          if voltage ~= nil and not voltageReported then
            voltageReported = true
            values:update("Voltage", string.format("%.0f", voltage), "NUMBER", nil, " V")
          end
        elseif n == 1 then
          -- Device without an energy meter; don't keep asking.
          log:info("Device does not support energy metering; disabling energy polling")
          CancelTimer("EnergyPoll")
          energyInFlight = false
          return
        end
        pollOutput(n + 1)
      end),
      live(generation, function(err)
        log:debug("energy poll for output %d failed: %s", n, Select(err, "error") or err)
        energyInFlight = false
      end)
    )
  end

  pollOutput(1)
end

--- Forward declaration; defined below with the transport detection logic.
local reconnect

--- (Re)start the polling timers from the current property values.
local function restartPollTimers()
  CancelTimer("SysinfoPoll")
  CancelTimer("EnergyPoll")

  local pollSeconds = tointeger(Properties["Poll Rate (Seconds)"]) or 10
  SetTimer("SysinfoPoll", pollSeconds * ONE_SECOND, function()
    if transport ~= nil then
      pollSysinfo()
    elseif not detecting then
      -- Detection found no device; keep retrying until it answers.
      reconnect(true)
    end
  end, true)

  local energySeconds = tointeger(Properties["Energy Poll Rate (Seconds)"]) or 0
  if energySeconds > 0 then
    SetTimer("EnergyPoll", energySeconds * ONE_SECOND, pollEnergy, true)
  end
end

--- Select a transport and mark the device online from a successful probe.
--- @param t Klap|Legacy
--- @param name string
--- @param sysinfo table The probe's get_sysinfo result.
local function adoptTransport(t, name, sysinfo)
  detecting = false
  if not follower:accepts(sysinfo.mac) then
    anotherDevice()
    return
  end
  missedPolls = 0
  transport = t
  transportName = name
  log:info("Using %s transport", name)
  applySysinfo(sysinfo)
  setDeviceOnline(true)
end

--- Probe the legacy (port 9999) transport with a get_sysinfo request.
--- @param generation integer The connect attempt the probe is for.
--- @param onFail fun(reason: string)
local function tryLegacy(generation, onFail)
  legacy:request({ system = { get_sysinfo = {} } }):next(
    live(generation, function(response)
      local sysinfo = Select(response, "system", "get_sysinfo")
      if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
        adoptTransport(legacy, "Legacy", sysinfo)
      else
        onFail("device rejected get_sysinfo over legacy protocol")
      end
    end),
    live(generation, function(err)
      onFail(Select(err, "error") or "no response over legacy protocol")
    end)
  )
end

--- Probe an established KLAP or TPAP session with an IOT-schema get_sysinfo.
--- @param t Klap|Tpap
--- @param name string Transport name for Driver Status.
--- @param generation integer The connect attempt the probe is for.
--- @param onFail fun(reason: string)
local function tryIot(t, name, generation, onFail)
  t:request({ system = { get_sysinfo = {} } }):next(
    live(generation, function(response)
      local sysinfo = Select(response, "system", "get_sysinfo")
      if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
        adoptTransport(t, name, sysinfo)
      else
        onFail("device rejected get_sysinfo over " .. name)
      end
    end),
    live(generation, function(err)
      onFail(Select(err, "error") or (name .. " request failed"))
    end)
  )
end

--- Probe an established session with a SMART-schema get_device_info (the
--- smart adapter translates it to/from the IOT shapes the driver reads).
--- @param adapter Smart
--- @param name string Transport name for Driver Status.
--- @param generation integer The connect attempt the probe is for.
--- @param onFail fun(reason: string)
local function trySmart(adapter, name, generation, onFail)
  adapter:request({ system = { get_sysinfo = {} } }):next(
    live(generation, function(response)
      local sysinfo = Select(response, "system", "get_sysinfo")
      if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
        adoptTransport(adapter, name, sysinfo)
      else
        onFail("device rejected get_device_info over " .. name)
      end
    end),
    live(generation, function(err)
      onFail(Select(err, "error") or "SMART request failed")
    end)
  )
end

--- Probe the KLAP transports: v2 handshake, then the SMART schema (EP25
--- v2.6/KP125M/Tapo), then the legacy IOT schema over the same session. A v2
--- auth mismatch retries the handshake with v1 hashing, which legacy Kasa
--- devices use after their KLAP firmware update.
--- @param generation integer The connect attempt the probe is for.
--- @param onFail fun(reason: string, code: number?) code is the HTTP status of a
---   refused handshake, if any.
local function tryKlap(generation, onFail)
  klap:connect():next(
    live(generation, function()
      trySmart(smart, "SMART", generation, function(smartReason)
        log:info("SMART probe failed (%s); trying legacy IOT schema over KLAP", smartReason)
        tryIot(klap, "KLAP", generation, onFail)
      end)
    end),
    live(generation, function(err)
      local reason = Select(err, "error") or "KLAP connection failed"
      if string.find(reason, "auth mismatch", 1, true) == nil then
        onFail(reason, Select(err, "code"))
        return
      end
      log:info("KLAP v2 handshake failed (%s); retrying with v1 hashing", reason)
      klapV1:connect():next(
        live(generation, function()
          tryIot(klapV1, "KLAP", generation, onFail)
        end),
        live(generation, function(v1Err)
          onFail(Select(v1Err, "error") or "KLAP connection failed", Select(v1Err, "code"))
        end)
      )
    end)
  )
end

--- Probe TPAP: ask the device whether it uses it, log in, then the SMART
--- schema and the IOT schema over the session.
--- @param ip string
--- @param generation integer The connect attempt the probe is for.
--- @param onFail fun(reason: string, final: boolean?) final is set when TPAP
---   answered for the device and its reason is the one to show.
local function tryTpap(ip, generation, onFail)
  Tpap.discover(ip):next(
    live(generation, function(info)
      if info == nil then
        onFail("the device does not use TPAP")
        return
      end
      if not Tpap.supports(info) then
        onFail(
          "the device asks for a login this driver does not support yet; turn on Third-Party Compatibility in the Tapo or Kasa app",
          true
        )
        return
      end
      tpap:configure({ port = info.port })
      tpap:connect():next(
        live(generation, function()
          trySmart(smartTpap, "TPAP", generation, function(smartReason)
            log:info("SMART probe failed (%s); trying legacy IOT schema over TPAP", smartReason)
            tryIot(tpap, "TPAP", generation, function(reason)
              onFail(reason, true)
            end)
          end)
        end),
        live(generation, function(err)
          onFail(Select(err, "error") or "TPAP login failed", true)
        end)
      )
    end),
    live(generation, function(err)
      onFail(Select(err, "error") or "no answer to TPAP discover", Select(err, "locked") ~= nil)
    end)
  )
end

--- A poll the device did not answer. From the third in a row the next poll
--- detects its protocol again, as a firmware update, a rollback or a reset
--- can change it; one lost answer keeps the session.
--- @param reason string?
function missedPoll(reason)
  missedPolls = missedPolls + 1
  if missedPolls >= 3 then
    transport = nil
    transportName = nil
  end
  setDeviceOnline(false, reason)
end

--- Another device answers at the device's address: control nothing there, and
--- look for the device on the network.
function anotherDevice()
  local ip = Properties["IP Address"] or ""
  log:warn("A device other than this one answers at %s", ip)
  missedPolls = 0
  transport = nil
  transportName = nil
  setDeviceOnline(false, "a different device is at " .. ip .. "; looking for this one")
  follower:lost()
end

--- No protocol reached the device at its address: it may have moved.
--- @param reason string
local function detectionFailed(reason)
  detecting = false
  setDeviceOnline(false, reason)
  follower:lost()
end

--- Driver Status while the device is searched for on the network.
local LOOKING_STATUS = "Looking for the device on the network..."

--- Driver Status as it was when the search began.
--- @type string?
local statusBeforeLooking = nil

follower = Discovery.Follower:new(function(address)
  if address == Properties["IP Address"] then
    return
  end
  log:info("The device moved to %s", address)
  UpdateProperty("IP Address", address)
  reconnect()
end, function(looking)
  if looking then
    statusBeforeLooking = Properties["Driver Status"]
    updateDriverStatus(LOOKING_STATUS)
  elseif Properties["Driver Status"] == LOOKING_STATUS then
    updateDriverStatus(statusBeforeLooking or "")
  end
end)

--- Reconfigure the transports from properties, detect the right one, and poll.
--- @param retry boolean? The poll timer trying again after no device was found.
function reconnect(retry)
  connectGeneration = connectGeneration + 1
  local generation = connectGeneration
  detecting = false
  transport = nil
  transportName = nil
  sysinfoInFlight = false
  energyInFlight = false

  local ip = Properties["IP Address"] or ""
  local config = {
    ip = ip,
    username = Properties["TP-Link Username"] or "",
    password = Properties["TP-Link Password"] or "",
  }
  klap:configure(config)
  klapV1:configure(config)
  smart:reset()
  tpap:configure(config)
  smartTpap:reset()
  legacy:configure({ ip = ip })
  -- A probe the last attempt left on the legacy port would hold this one's.
  legacy:reset()

  if IsEmpty(ip) then
    updateDriverStatus("Set the IP Address property")
    return
  end

  local mode = Properties["Protocol"] or "Auto"
  local hasCredentials = not IsEmpty(Properties["TP-Link Username"]) and not IsEmpty(Properties["TP-Link Password"])

  --- Say which protocol is being tried. A retry says nothing: the reason the
  --- last attempt failed for stays up until this one ends another way.
  --- @param name string
  local function connecting(name)
    if not retry then
      updateDriverStatus("Connecting (" .. name .. ")...")
    end
  end

  if mode == "TPAP" then
    if not hasCredentials then
      updateDriverStatus("Set the TP-Link Username and Password properties (required for TPAP)")
      return
    end
    detecting = true
    connecting("TPAP")
    tryTpap(ip, generation, detectionFailed)
  elseif mode == "KLAP" or (mode == "Auto" and hasCredentials) then
    if not hasCredentials then
      updateDriverStatus("Set the TP-Link Username and Password properties (required for KLAP)")
      return
    end
    detecting = true
    connecting("KLAP")
    tryKlap(generation, function(klapReason, klapCode)
      if mode == "KLAP" then
        detectionFailed(klapReason)
        return
      end
      --- Always fall back to legacy, even on an auth mismatch: transitional
      --- Kasa firmware (e.g. KP115 1.1.1) answers KLAP with credentials that
      --- match no known scheme while still serving the legacy protocol. If
      --- legacy also fails, the combined reason still surfaces the mismatch.
      local function fallBack()
        log:info("KLAP probe failed (%s); trying legacy protocol", klapReason)
        connecting("Legacy")
        tryLegacy(generation, function(legacyReason)
          if klapCode == 403 then
            log:info("Legacy probe failed: %s", legacyReason)
            detectionFailed(klapReason)
            return
          end
          detectionFailed("KLAP: " .. klapReason .. " / Legacy: " .. legacyReason)
        end)
      end
      -- A device whose account has Third-Party Compatibility off refuses KLAP
      -- (403, or 500 on some light strips) and takes TPAP instead.
      if klapCode ~= 403 and klapCode ~= 500 then
        fallBack()
        return
      end
      log:info("KLAP refused (%s); trying TPAP", klapReason)
      connecting("TPAP")
      tryTpap(ip, generation, function(tpapReason, final)
        if final then
          detectionFailed(tpapReason)
        else
          log:info("TPAP probe failed: %s", tpapReason)
          fallBack()
        end
      end)
    end)
  else
    -- Legacy mode, or Auto without credentials.
    detecting = true
    connecting("Legacy")
    tryLegacy(generation, function(legacyReason)
      if mode == "Auto" then
        legacyReason = legacyReason .. " (set TP-Link credentials if this device is on KLAP firmware)"
      end
      detectionFailed(legacyReason)
    end)
  end
end

---------------------------------------------------------------------------
-- Control
---------------------------------------------------------------------------

--- Set the relay state of an output on the device.
--- @param n number Output number (1-based).
--- @param state boolean
function setOutput(n, state)
  log:debug("setOutput(%s, %s)", n, state)
  if n < 1 or (outputCount > 0 and n > outputCount) then
    log:warn("setOutput: output %s does not exist on this device", n)
    return
  end
  if transport == nil then
    log:warn("setOutput: not connected")
    return
  end
  outputs[n] = outputs[n] or {}
  local generation = connectGeneration
  transport:request(forOutput(n, { system = { set_relay_state = { state = state and 1 or 0 } } })):next(
    live(generation, function(response)
      local result = Select(response, "system", "set_relay_state")
      if type(result) ~= "table" or tointeger(result.err_code) ~= 0 then
        log:error("set_relay_state for output %d failed: %s", n, response)
        return
      end
      applyOutputState(n, state)
    end),
    live(generation, function(err)
      log:error("Failed to set output %d %s: %s", n, state and "on" or "off", Select(err, "error") or err)
      setDeviceOnline(false, Select(err, "error"))
    end)
  )
end

--- Toggle an output based on its last known state.
--- @param n number Output number (1-based).
function toggleOutput(n)
  setOutput(n, not Select(outputs, n, "state"))
end

---------------------------------------------------------------------------
-- Conditionals
---------------------------------------------------------------------------

function TC.DEVICE_CONNECTED()
  log:trace("TC.DEVICE_CONNECTED()")
  return deviceOnline
end

---------------------------------------------------------------------------
-- Property Changed Handlers
---------------------------------------------------------------------------

--- @param propertyValue string
function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--#ifndef DRIVERCENTRAL
--- @param propertyValue string
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if gInitialized then
    updateSettings:share("Update Channel", propertyValue)
  end
end
--#endif

--- An update setting changed on another item.
--- @param params table
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--#ifdef DRIVERCENTRAL
--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end
--#endif

--- @param propertyValue string
function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

--- @param propertyValue string
function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

--- @param propertyValue string
function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

--- @param propertyValue string
function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

--- @param propertyValue string
function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  -- An address set by hand may be another device's, as a replacement's is. The
  -- follower's own write never reaches here; late init replays every property.
  if gInitialized then
    follower:forget()
    reconnect()
  end
end

-- The handler library prints a property's value at Log Level "6 - Ultra".
OPC.suppressDebug["TP-Link Username"] = true
OPC.suppressDebug["TP-Link Password"] = true

--- Reconnect for a changed credential. It must not raise: the handler
--- library prints the value of a property whose handler does.
local function credentialChanged()
  if not gInitialized then
    return
  end
  local ok, err = pcall(reconnect)
  if not ok then
    log:error("The reconnect did not run: %s", err)
    --#ifdef DRIVERCENTRAL
    diagnostics:captureError(tostring(err), nil, "TPLinkOutlet.CredentialChanged")
    --#endif
  end
end

function OPC.TP_Link_Username()
  log:trace("OPC.TP_Link_Username(<redacted>)")
  credentialChanged()
end

function OPC.TP_Link_Password()
  log:trace("OPC.TP_Link_Password(<redacted>)")
  credentialChanged()
end

--- @param propertyValue string
function OPC.Protocol(propertyValue)
  log:trace("OPC.Protocol('%s')", propertyValue)
  if gInitialized then
    reconnect()
  end
end

--- @param propertyValue string
function OPC.Poll_Rate_Seconds(propertyValue)
  log:trace("OPC.Poll_Rate_Seconds('%s')", propertyValue)
  if gInitialized then
    restartPollTimers()
  end
end

--- @param propertyValue string
function OPC.Energy_Poll_Rate_Seconds(propertyValue)
  log:trace("OPC.Energy_Poll_Rate_Seconds('%s')", propertyValue)
  if gInitialized then
    restartPollTimers()
  end
end

-- A changed level takes the next reading as the output's state, not a change.
for n = 1, constants.MAX_OUTPUTS do
  local function rebaseline()
    if outputs[n] ~= nil then
      outputs[n].inUse, outputs[n].heldSince = nil, nil
    end
  end
  OPC["Output_" .. n .. "_In_Use_Above_W"] = rebaseline
  OPC["Output_" .. n .. "_Idle_Below_W"] = rebaseline
  OPC["Output_" .. n .. "_Hold_s"] = rebaseline
end

---------------------------------------------------------------------------
-- Command Handlers (Composer programming)
---------------------------------------------------------------------------

--- @param tParams table
function EC.Turn_Output_On(tParams)
  log:trace("EC.Turn_Output_On(%s)", tParams)
  local n = tointeger(tParams.Output)
  if n then
    setOutput(n, true)
  end
end

--- @param tParams table
function EC.Turn_Output_Off(tParams)
  log:trace("EC.Turn_Output_Off(%s)", tParams)
  local n = tointeger(tParams.Output)
  if n then
    setOutput(n, false)
  end
end

--- @param tParams table
function EC.Toggle_Output(tParams)
  log:trace("EC.Toggle_Output(%s)", tParams)
  local n = tointeger(tParams.Output)
  if n then
    toggleOutput(n)
  end
end

---------------------------------------------------------------------------
-- Action Handlers
---------------------------------------------------------------------------

function EC.RefreshNow()
  log:info("Action: Refresh Now")
  pollSysinfo()
  pollEnergy()
end

function EC.Reconnect()
  log:info("Action: Reconnect")
  -- No transport reset first: it would fail requests whose callbacks are still
  -- live and mark a working device offline.
  reconnect()
end

--#ifndef DRIVERCENTRAL
--- Update Drivers action handler.
function EC.UpdateDrivers()
  log:trace("EC.UpdateDrivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

--- Update the driver from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if the driver is up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, driverFilenames, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers: %s", error)
    end)
end
--#endif

---------------------------------------------------------------------------
-- Driver Lifecycle
---------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Hide device-shaped properties; sysinfo and values re-show the ones in use.
  for _, property in ipairs(DEVICE_PROPERTIES) do
    C4:SetPropertyAttribs(property, constants.HIDE_PROPERTY)
  end
  C4:SetPropertyAttribs("Outputs", constants.HIDE_PROPERTY)
  C4:SetPropertyAttribs("Voltage", constants.HIDE_PROPERTY)
  for n = 1, constants.MAX_OUTPUTS do
    C4:SetPropertyAttribs("Output " .. n .. " Name", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Output " .. n .. " State", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Output " .. n .. " Power", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Output " .. n .. " In Use Above (W)", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Output " .. n .. " Idle Below (W)", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Output " .. n .. " Hold (s)", constants.HIDE_PROPERTY)
  end

  -- Restore dynamic bindings and output variables here: programming attached
  -- to variables added after OnDriverInit may not work after a Director
  -- restart.
  bindings:restoreBindings()
  values:restoreValues()
  restoreRelayHandlers()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged for all properties to ensure consistent state
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  --#ifndef DRIVERCENTRAL
  -- Periodic update check (every 30 minutes, leader instance only)
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    -- Recompute leader each cycle in case the previous leader was removed
    local isLeaderInstance = Select(getDriverIds(), 1) == C4:GetDeviceID()
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true

  reconnect()
  restartPollTimers()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  log:info("TP-Link Outlet driver shutting down")
  CancelTimer("SysinfoPoll")
  CancelTimer("EnergyPoll")
  follower:stop()
end
