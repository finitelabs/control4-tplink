--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "tplink_outlet.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-tplink"
DRIVER_FILENAMES = {
  "tplink_outlet.c4z",
  "tplink_light.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

local log = require("lib.logging")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif
local constants = require("constants")
local bindings = require("lib.bindings")
local values = require("lib.values")
local Klap = require("lib.klap")
local Legacy = require("lib.legacy")
local Smart = require("lib.smart")

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

--- The active transport, set by connect-time detection.
--- @type Klap|Legacy|Smart|nil
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
  for _, filename in ipairs(DRIVER_FILENAMES) do
    for id, _ in pairs(C4:GetDevicesByC4iName(filename) or {}) do
      table.insert(ids, tointeger(id))
    end
  end
  table.sort(ids)
  return ids
end

--- Sync a property value to all other instances of this driver.
--- Only syncs if the other instance has a different value (avoids infinite loops).
--- @param propertyName string
--- @param propertyValue string
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local ids = getDriverIds()
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(ids) do
    if deviceId ~= myId then
      log:info("Syncing property '%s' = '%s' to device %d", propertyName, propertyValue, deviceId)
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
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
    updateDriverStatus(transportName and ("Connected (" .. transportName .. ")") or "Connected")
  else
    updateDriverStatus(not IsEmpty(reason) and ("Disconnected: " .. reason) or "Disconnected")
    for _, binding in pairs(bindings:getDynamicBindings("light")) do
      SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
    end
  end
end

--- Forward declared; defined in the Control section.
local setOutput, toggleOutput

--- Get or create the dynamic relay binding for an output and wire its handlers.
--- @param n number Output number (1-based).
--- @return integer|nil bindingId
local function ensureRelayBinding(n)
  local binding =
    bindings:getOrAddDynamicBinding("relay", "output_" .. n, "CONTROL", true, "Output " .. n .. " Relay", "RELAY")
  if binding == nil then
    return nil
  end

  RFP[binding.bindingId] = function(_, strCommand, tParams)
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
    end
  end

  OBC[binding.bindingId] = function(idBinding, _, bIsBound)
    if bIsBound and outputs[n] and outputs[n].state ~= nil then
      SendToProxy(idBinding, outputs[n].state and "CLOSED" or "OPENED", {}, "NOTIFY")
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
end

--- Apply a new relay state for an output: value, events, relay proxy.
--- @param n number Output number (1-based).
--- @param state boolean New relay state.
local function applyOutputState(n, state)
  local changed = values:update("Output " .. n .. " State", state, "BOOL")
  outputs[n].state = state

  if changed then
    local binding = bindings:getDynamicBinding("relay", "output_" .. n)
    if binding then
      SendToProxy(binding.bindingId, state and "CLOSED" or "OPENED", {}, "NOTIFY")
    end
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
      outputs[n].childId = tostring(child.id)
      ensureRelayBinding(n)
      ensureLightBinding(n)
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
  transport:request({ system = { get_sysinfo = {} } }):next(function(response)
    sysinfoInFlight = false
    local sysinfo = Select(response, "system", "get_sysinfo")
    if type(sysinfo) ~= "table" or tointeger(sysinfo.err_code) ~= 0 then
      log:warn("get_sysinfo failed: %s", response)
      setDeviceOnline(false, "device rejected get_sysinfo")
      return
    end
    applySysinfo(sysinfo)
    setDeviceOnline(true)
  end, function(err)
    sysinfoInFlight = false
    log:warn("sysinfo poll failed: %s", Select(err, "error") or err)
    setDeviceOnline(false, Select(err, "error"))
  end)
end

--- Poll per-output power usage via emeter get_realtime, one output after another.
local function pollEnergy()
  if transport == nil or energyInFlight or outputCount == 0 or not deviceOnline then
    return
  end
  energyInFlight = true

  local voltageReported = false

  local function pollOutput(n)
    if n > outputCount then
      energyInFlight = false
      return
    end
    transport:request(forOutput(n, { emeter = { get_realtime = {} } })):next(function(response)
      local realtime = Select(response, "emeter", "get_realtime")
      if type(realtime) == "table" and tointeger(realtime.err_code) == 0 then
        -- Hardware v1 reports floats in base units (power/voltage); v2 reports
        -- integers in milli-units (power_mw/voltage_mv).
        local watts = realtime.power_mw ~= nil and (tonumber_locale(realtime.power_mw) or 0) / 1000
          or tonumber_locale(realtime.power)
        if watts ~= nil then
          values:update("Output " .. n .. " Power", string.format("%.1f", watts), "NUMBER", nil, " W")
        end
        local voltage = realtime.voltage_mv ~= nil and (tonumber_locale(realtime.voltage_mv) or 0) / 1000
          or tonumber_locale(realtime.voltage)
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
    end, function(err)
      log:debug("energy poll for output %d failed: %s", n, Select(err, "error") or err)
      energyInFlight = false
    end)
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
  SetTimer("SysinfoPoll", pollSeconds * 1000, function()
    if transport == nil then
      -- Detection failed or never ran; keep retrying until the device answers.
      reconnect()
    else
      pollSysinfo()
    end
  end, true)

  local energySeconds = tointeger(Properties["Energy Poll Rate (Seconds)"]) or 0
  if energySeconds > 0 then
    SetTimer("EnergyPoll", energySeconds * 1000, pollEnergy, true)
  end
end

--- Select a transport and mark the device online from a successful probe.
--- @param t Klap|Legacy
--- @param name string
--- @param sysinfo table The probe's get_sysinfo result.
local function adoptTransport(t, name, sysinfo)
  transport = t
  transportName = name
  log:info("Using %s transport", name)
  applySysinfo(sysinfo)
  setDeviceOnline(true)
end

--- Probe the legacy (port 9999) transport with a get_sysinfo request.
--- @param onFail fun(reason: string)
local function tryLegacy(onFail)
  legacy:request({ system = { get_sysinfo = {} } }):next(function(response)
    local sysinfo = Select(response, "system", "get_sysinfo")
    if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
      adoptTransport(legacy, "Legacy", sysinfo)
    else
      onFail("device rejected get_sysinfo over legacy protocol")
    end
  end, function(err)
    onFail(Select(err, "error") or "no response over legacy protocol")
  end)
end

--- Probe an established KLAP session with an IOT-schema get_sysinfo.
--- @param t Klap
--- @param onFail fun(reason: string)
local function tryKlapIot(t, onFail)
  t:request({ system = { get_sysinfo = {} } }):next(function(response)
    local sysinfo = Select(response, "system", "get_sysinfo")
    if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
      adoptTransport(t, "KLAP", sysinfo)
    else
      onFail("device rejected get_sysinfo over KLAP")
    end
  end, function(err)
    onFail(Select(err, "error") or "KLAP request failed")
  end)
end

--- Probe an established KLAP v2 session with a SMART-schema get_device_info
--- (the smart adapter translates it to/from the IOT shapes the driver reads).
--- @param onFail fun(reason: string)
local function trySmart(onFail)
  smart:request({ system = { get_sysinfo = {} } }):next(function(response)
    local sysinfo = Select(response, "system", "get_sysinfo")
    if type(sysinfo) == "table" and tointeger(sysinfo.err_code) == 0 then
      adoptTransport(smart, "SMART", sysinfo)
    else
      onFail("device rejected get_device_info over KLAP")
    end
  end, function(err)
    onFail(Select(err, "error") or "SMART request failed")
  end)
end

--- Probe the KLAP transports: v2 handshake, then the SMART schema (EP25
--- v2.6/KP125M/Tapo), then the legacy IOT schema over the same session. A v2
--- auth mismatch retries the handshake with v1 hashing, which legacy Kasa
--- devices use after their KLAP firmware update.
--- @param onFail fun(reason: string)
local function tryKlap(onFail)
  klap:connect():next(function()
    trySmart(function(smartReason)
      log:info("SMART probe failed (%s); trying legacy IOT schema over KLAP", smartReason)
      tryKlapIot(klap, onFail)
    end)
  end, function(err)
    local reason = Select(err, "error") or "KLAP connection failed"
    if string.find(reason, "auth mismatch", 1, true) == nil then
      onFail(reason)
      return
    end
    log:info("KLAP v2 handshake failed (%s); retrying with v1 hashing", reason)
    klapV1:connect():next(function()
      tryKlapIot(klapV1, onFail)
    end, function(v1Err)
      onFail(Select(v1Err, "error") or "KLAP connection failed")
    end)
  end)
end

--- Reconfigure the transports from properties, detect the right one, and poll.
function reconnect()
  transport = nil
  transportName = nil

  local ip = Properties["IP Address"] or ""
  local config = {
    ip = ip,
    username = Properties["TP-Link Username"] or "",
    password = Properties["TP-Link Password"] or "",
  }
  klap:configure(config)
  klapV1:configure(config)
  smart:reset()
  legacy:configure({ ip = ip })

  if IsEmpty(ip) then
    updateDriverStatus("Set the IP Address property")
    return
  end

  local mode = Properties["Protocol"] or "Auto"
  local hasCredentials = not IsEmpty(Properties["TP-Link Username"]) and not IsEmpty(Properties["TP-Link Password"])

  if mode == "KLAP" or (mode == "Auto" and hasCredentials) then
    if not hasCredentials then
      updateDriverStatus("Set the TP-Link Username and Password properties (required for KLAP)")
      return
    end
    updateDriverStatus("Connecting (KLAP)...")
    tryKlap(function(klapReason)
      if mode == "KLAP" then
        setDeviceOnline(false, klapReason)
        return
      end
      -- Always fall back to legacy, even on an auth mismatch: transitional
      -- Kasa firmware (e.g. KP115 1.1.1) answers KLAP with credentials that
      -- match no known scheme while still serving the legacy protocol. If
      -- legacy also fails, the combined reason still surfaces the mismatch.
      log:info("KLAP probe failed (%s); trying legacy protocol", klapReason)
      updateDriverStatus("Connecting (Legacy)...")
      tryLegacy(function(legacyReason)
        setDeviceOnline(false, "KLAP: " .. klapReason .. " / Legacy: " .. legacyReason)
      end)
    end)
  else
    -- Legacy mode, or Auto without credentials.
    updateDriverStatus("Connecting (Legacy)...")
    tryLegacy(function(legacyReason)
      if mode == "Auto" then
        legacyReason = legacyReason .. " (set TP-Link credentials if this device is on KLAP firmware)"
      end
      setDeviceOnline(false, legacyReason)
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
  transport
    :request(forOutput(n, { system = { set_relay_state = { state = state and 1 or 0 } } }))
    :next(function(response)
      local result = Select(response, "system", "set_relay_state")
      if type(result) ~= "table" or tointeger(result.err_code) ~= 0 then
        log:error("set_relay_state for output %d failed: %s", n, response)
        return
      end
      applyOutputState(n, state)
    end, function(err)
      log:error("Failed to set output %d %s: %s", n, state and "on" or "off", Select(err, "error") or err)
      setDeviceOnline(false, Select(err, "error"))
    end)
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
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
--- @param propertyValue string
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

--- @param propertyValue string
function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end

--- @param propertyValue string
function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
end

--- @param propertyValue string
function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  if gInitialized then
    reconnect()
  end
end

function OPC.TP_Link_Username(propertyValue)
  log:trace("OPC.TP_Link_Username('%s')", propertyValue)
  if gInitialized then
    reconnect()
  end
end

function OPC.TP_Link_Password()
  log:trace("OPC.TP_Link_Password(<redacted>)")
  if gInitialized then
    reconnect()
  end
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
  klap:reset()
  klapV1:reset()
  smart:reset()
  legacy:reset()
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
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
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
  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")

  -- Set driver version
  UpdateProperty("Driver Version", C4:GetDeviceData(C4:GetDeviceID(), "version"))

  -- Fire OnPropertyChanged for all properties to ensure consistent state
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  --#ifndef DRIVERCENTRAL
  -- Periodic update check (every 30 minutes, leader instance only)
  SetTimer("UpdateCheck", 30 * 60 * 1000, function()
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

function OnDriverDestroyed()
  log:info("TP-Link Outlet driver shutting down")
  CancelTimer("SysinfoPoll")
  CancelTimer("EnergyPoll")
end
