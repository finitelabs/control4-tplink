--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "kasa_power_strip.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-kasa"
DRIVER_FILENAMES = {
  "kasa_power_strip.c4z",
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
local Klap = require("lib.klap")

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

--- Driver initialization flag.
--- @type boolean
local gInitialized = false

--- KLAP transport to the device.
--- @type Klap
local klap = Klap:new()

--- @class Output
--- @field childId string? The device-side child id ("" context id for single-outlet devices).
--- @field name string? The output alias reported by the device.
--- @field state boolean? Last known relay state.
--- @field watts number? Last known power draw in watts.

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

--#ifndef DRIVERCENTRAL
--- Get all device IDs for instances of this driver, sorted ascending.
--- @return integer[]
local function getDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id, _ in pairs(drivers) do
    table.insert(ids, tointeger(id))
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
    updateDriverStatus("Connected")
  else
    updateDriverStatus(not IsEmpty(reason) and ("Disconnected: " .. reason) or "Disconnected")
  end
end

--- Update the "Output N" display property from the output's last known state.
--- @param n number Output number (1-based).
local function updateOutputProperty(n)
  local output = outputs[n]
  if not output then
    return
  end
  local parts = { output.name or ("Output " .. n) }
  table.insert(parts, output.state and "On" or "Off")
  if output.watts ~= nil then
    table.insert(parts, string.format("%.1f W", output.watts))
  end
  UpdateProperty("Output " .. n, table.concat(parts, " — "))
end

--- Apply a new relay state for an output: variables, events, relay proxy, property.
--- @param n number Output number (1-based).
--- @param state boolean New relay state.
--- @param forceNotify boolean? Notify even if the state did not change.
local function applyOutputState(n, state, forceNotify)
  local output = outputs[n]
  local changed = output.state ~= state
  output.state = state

  if changed or forceNotify then
    SetVariable("OUTPUT_" .. n .. "_STATE", state and "1" or "0")
    SendToProxy(constants.RELAY_BINDING_BASE + n, state and "CLOSED" or "OPENED", {}, "NOTIFY")
    updateOutputProperty(n)
  end
  if changed and gInitialized then
    C4:FireEventByID(state and n or (constants.EVENT_OFF_OFFSET + n))
  end
end

--- Apply a new output name: variable and display property.
--- @param n number Output number (1-based).
--- @param name string
local function applyOutputName(n, name)
  local output = outputs[n]
  if output.name ~= name then
    output.name = name
    SetVariable("OUTPUT_" .. n .. "_NAME", name)
    updateOutputProperty(n)
  end
end

--- Apply a new power reading: variable and display property.
--- @param n number Output number (1-based).
--- @param watts number
local function applyOutputWatts(n, watts)
  local output = outputs[n]
  output.watts = watts
  -- OUTPUT_n_WATT is a NUMBER variable; report whole watts like the device app does.
  SetVariable("OUTPUT_" .. n .. "_WATT", tostring(math.floor(watts + 0.5)))
  updateOutputProperty(n)
end

--- Parse a get_sysinfo response body and update all output/device state.
--- @param sysinfo table The `system.get_sysinfo` result.
local function applySysinfo(sysinfo)
  UpdateProperty("Model", tostring(sysinfo.model or ""))
  UpdateProperty("Device Name", tostring(sysinfo.alias or ""))
  UpdateProperty("MAC Address", tostring(sysinfo.mac or ""))
  UpdateProperty("Firmware", tostring(sysinfo.sw_ver or ""))
  UpdateProperty("WiFi RSSI", tostring(sysinfo.rssi or ""))

  local children = sysinfo.children
  if type(children) == "table" and #children > 0 then
    outputCount = math.min(#children, constants.MAX_OUTPUTS)
    for i = 1, outputCount do
      local child = children[i]
      outputs[i] = outputs[i] or {}
      outputs[i].childId = tostring(child.id)
      applyOutputName(i, tostring(child.alias or ("Output " .. i)))
      applyOutputState(i, tointeger(child.state) == 1)
    end
  else
    -- Single-outlet device (HS103/HS110/KP115/...): no children, top-level relay_state.
    outputCount = 1
    outputs[1] = outputs[1] or {}
    outputs[1].childId = nil
    applyOutputName(1, tostring(sysinfo.alias or "Output 1"))
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
  if sysinfoInFlight then
    log:debug("Skipping sysinfo poll; previous poll still in flight")
    return
  end
  sysinfoInFlight = true
  klap:request({ system = { get_sysinfo = {} } }):next(function(response)
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
  if energyInFlight or outputCount == 0 or not deviceOnline then
    return
  end
  energyInFlight = true

  local voltageReported = false

  local function pollOutput(n)
    if n > outputCount then
      energyInFlight = false
      return
    end
    klap:request(forOutput(n, { emeter = { get_realtime = {} } })):next(function(response)
      local realtime = Select(response, "emeter", "get_realtime")
      if type(realtime) == "table" and tointeger(realtime.err_code) == 0 then
        -- Hardware v1 reports floats in base units (power/voltage); v2 reports
        -- integers in milli-units (power_mw/voltage_mv).
        local watts = realtime.power_mw ~= nil and (tonumber_locale(realtime.power_mw) or 0) / 1000
          or tonumber_locale(realtime.power)
        if watts ~= nil then
          applyOutputWatts(n, watts)
        end
        local voltage = realtime.voltage_mv ~= nil and (tonumber_locale(realtime.voltage_mv) or 0) / 1000
          or tonumber_locale(realtime.voltage)
        if voltage ~= nil and not voltageReported then
          voltageReported = true
          SetVariable("VOLTAGE", tostring(math.floor(voltage + 0.5)))
          UpdateProperty("Voltage", string.format("%.0f V", voltage))
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

--- (Re)start the polling timers from the current property values.
local function restartPollTimers()
  CancelTimer("SysinfoPoll")
  CancelTimer("EnergyPoll")

  local pollSeconds = tointeger(Properties["Poll Rate (Seconds)"]) or 10
  SetTimer("SysinfoPoll", pollSeconds * 1000, pollSysinfo, true)

  local energySeconds = tointeger(Properties["Energy Poll Rate (Seconds)"]) or 0
  if energySeconds > 0 then
    SetTimer("EnergyPoll", energySeconds * 1000, pollEnergy, true)
  end
end

--- Reconfigure the transport from properties and poll immediately.
local function reconnect()
  klap:configure({
    ip = Properties["IP Address"] or "",
    username = Properties["TP-Link Username"] or "",
    password = Properties["TP-Link Password"] or "",
  })
  if IsEmpty(Properties["IP Address"]) then
    updateDriverStatus("Set the IP Address property")
    return
  end
  if IsEmpty(Properties["TP-Link Username"]) or IsEmpty(Properties["TP-Link Password"]) then
    updateDriverStatus("Set the TP-Link Username and Password properties")
    return
  end
  updateDriverStatus("Connecting...")
  pollSysinfo()
end

---------------------------------------------------------------------------
-- Control
---------------------------------------------------------------------------

--- Set the relay state of an output on the device.
--- @param n number Output number (1-based).
--- @param state boolean
local function setOutput(n, state)
  log:debug("setOutput(%s, %s)", n, state)
  if n < 1 or (outputCount > 0 and n > outputCount) then
    log:warn("setOutput: output %s does not exist on this device", n)
    return
  end
  outputs[n] = outputs[n] or {}
  klap:request(forOutput(n, { system = { set_relay_state = { state = state and 1 or 0 } } })):next(function(response)
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
local function toggleOutput(n)
  setOutput(n, not Select(outputs, n, "state"))
end

---------------------------------------------------------------------------
-- Relay Bindings
---------------------------------------------------------------------------

for n = 1, constants.MAX_OUTPUTS do
  RFP[constants.RELAY_BINDING_BASE + n] = function(idBinding, strCommand, tParams)
    log:trace("RFP relay idBinding=%s strCommand=%s", idBinding, strCommand)
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
end

-- Report current state to relay proxies when they (re)bind.
for n = 1, constants.MAX_OUTPUTS do
  OBC[constants.RELAY_BINDING_BASE + n] = function(idBinding, _, bIsBound)
    if bIsBound and outputs[n] and outputs[n].state ~= nil then
      SendToProxy(idBinding, outputs[n].state and "CLOSED" or "OPENED", {}, "NOTIFY")
    end
  end
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
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")

  -- Set driver version
  UpdateProperty("Driver Version", C4:GetDeviceData(C4:GetDeviceID(), "version"))

  -- Register variables with the same names the legacy Kasa outlet drivers used,
  -- so existing programming can be re-pointed 1:1.
  AddVariable("VOLTAGE", "0", "NUMBER", true)
  for n = 1, constants.MAX_OUTPUTS do
    AddVariable("OUTPUT_" .. n .. "_NAME", "", "STRING", true)
    AddVariable("OUTPUT_" .. n .. "_STATE", "0", "BOOL", true)
    AddVariable("OUTPUT_" .. n .. "_WATT", "0", "NUMBER", true)
    outputs[n] = outputs[n] or {}
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
  log:info("Kasa Power Strip driver shutting down")
  CancelTimer("SysinfoPoll")
  CancelTimer("EnergyPoll")
end
