-- TP-Link Light: a Kasa or Tapo bulb or light strip as a Control4 light, or a
-- lamp on a TP-Link Outlet output. Direct, it finds which protocol the light
-- speaks (KLAP, TPAP or the original Kasa one) and polls it; bound to an
-- outlet, the outlet reports its state and sends its commands. The light
-- library runs the light: its proxy, links, scenes and fades.

--#ifndef DRIVERCENTRAL
DRIVER_GITHUB_REPO = "finitelabs/control4-tplink"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

gInitialized = false

local log = require("lib.logging")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
local driverFilenames = require("lib.driver-filenames")
--#endif
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
local values = require("lib.values")
local Light = require("lib.light")
local Types = require("lib.light.types")
local TplinkLightAdapter = require("tplink.light_adapter")

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------

local PROXY_BINDING = 5001
--- Control consumer binding to a tplink_outlet output ("proxy mode"). When
--- bound, the outlet drives state and executes commands; otherwise the
--- driver connects directly to a light device using its properties.
local OUTLET_BINDING = 1

---------------------------------------------------------------------------
-- The light
---------------------------------------------------------------------------

--- What the light's connection tells the driver: its methods are set in the
--- Connection section.
--- @type TplinkLightHost
local host = {}

local adapter = TplinkLightAdapter.new(host, OUTLET_BINDING)

local light = Light.new(adapter, {
  api = Types.API,
  proxy = PROXY_BINDING,
  links = { top = 300, toggle = 301, bottom = 302 },
  dims = true,
  color = true,
  cct = true,
  fades = true,
  defaultOn = true,
  scenes = true,
  onModes = true,
  flash = true,
})

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

--- Update the driver suite from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if the drivers are up to date.
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

--- Update Drivers action handler.
function EC.UpdateDrivers()
  log:trace("EC.UpdateDrivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end
--#endif

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

---------------------------------------------------------------------------
-- Connection
---------------------------------------------------------------------------

--- Start reaching the light, unless no license lets it run.
--- @param retry boolean? The poll timer trying again after no light was found.
--- @return boolean started
local function connect(retry)
  --#ifdef DRIVERCENTRAL
  if not drivercentral:licensed() then
    adapter:stop()
    UpdateProperty("Driver Status", drivercentral.UNLICENSED_STATUS)
    return false
  end
  --#endif
  adapter:start(retry)
  return true
end

--- Reach the light afresh: it reads offline, at the level it had, until it
--- reports again. A retry after no light was found only tries again.
--- @param retry boolean?
local function restart(retry)
  if connect(retry) and not retry then
    light:reset()
  end
end

function host:declare(device)
  light:declare(device)
end

function host:report(report)
  light:report(report)
end

function host:lost()
  light:lost(false)
end

function host:restart(retry)
  restart(retry)
end

--#ifdef DRIVERCENTRAL
--- DriverCentral's license gate. Without a license the driver stops reaching
--- the light and its proxy shows it offline at the level it had, with no Light
--- Off; with one it starts again.
--- @param licensed boolean
local function licenseChanged(licensed)
  if licensed then
    log:info("License active; starting the light")
    restart()
    return
  end
  log:warn("No active license; stopping the light")
  adapter:stop()
  light:lost(true)
  UpdateProperty("Driver Status", drivercentral.UNLICENSED_STATUS)
end
--#endif

function RFP.UPDATE_STATE(idBinding, strCommand, tParams)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= OUTLET_BINDING then
    log:error("RFP.UPDATE_STATE called with idBinding %s, expected %s", idBinding, OUTLET_BINDING)
    return
  end
  --#ifdef DRIVERCENTRAL
  if not drivercentral:licensed() then
    return
  end
  --#endif
  adapter:outletUpdate(tParams)
end

function RFP.UPDATE_DISCONNECT(idBinding, strCommand)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s)", idBinding, strCommand)
  if idBinding ~= OUTLET_BINDING then
    return
  end
  --#ifdef DRIVERCENTRAL
  if not drivercentral:licensed() then
    return
  end
  --#endif
  adapter:lost()
end

--- A bind or an unbind changes how the light is reached. An off would run Light
--- Off programming, so it shows the light offline at its level until it
--- reports. A controller start binds before late init starts the light.
OBC[OUTLET_BINDING] = function(_, _, _bIsBound)
  if gInitialized then
    restart()
  end
end

---------------------------------------------------------------------------
-- Driver lifecycle
---------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged once per property to set initial globals. The router runs each
  -- handler in its own xpcall and reports a failure itself, so one property's error doesn't
  -- stop the rest.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end

  gInitialized = true

  --#ifndef DRIVERCENTRAL
  -- Periodic update check (every 30 minutes, suite leader instance only)
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    -- Recompute leader each cycle in case the previous leader was removed
    local isLeaderInstance = Select(getDriverIds(), 1) == C4:GetDeviceID()
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  UpdateProperty("Driver Status", "Disconnected")
  connect()
  light:start()
  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(licenseChanged)
  --#endif
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  adapter:stop()
  KillAllTimers()
end

---------------------------------------------------------------------------
-- Property handlers
---------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

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

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end

---------------------------------------------------------------------------
-- Property handlers: direct mode
---------------------------------------------------------------------------

--- @param propertyValue string
function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  -- An address set by hand may be another device's, as a replacement's is. The
  -- follower's own write never reaches here; late init replays every property.
  if gInitialized then
    adapter:forgetDevice()
    restart()
  end
end

--- @param propertyValue string
function OPC.Protocol(propertyValue)
  log:trace("OPC.Protocol('%s')", propertyValue)
  if gInitialized then
    restart()
  end
end

--- Reconnect action: discard any established sessions and re-detect.
function EC.Reconnect()
  log:info("Action: Reconnect")
  adapter:resetLinks()
  restart()
end

-- The handler library prints a property's value at Log Level "6 - Ultra".
OPC.suppressDebug["TP-Link Username"] = true
OPC.suppressDebug["TP-Link Password"] = true

--- Reach the light afresh with a changed credential. It must not raise: the
--- handler library prints the value of a property whose handler does.
local function credentialChanged()
  if not gInitialized then
    return
  end
  local ok, err = pcall(restart)
  if not ok then
    log:error("The light's connection did not start: %s", err)
    --#ifdef DRIVERCENTRAL
    diagnostics:captureError(tostring(err), nil, "TPLinkLight.CredentialChanged")
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
function OPC.Poll_Rate_Seconds(propertyValue)
  log:trace("OPC.Poll_Rate_Seconds('%s')", propertyValue)
  if gInitialized then
    restart()
  end
end

--- @param propertyValue string
function OPC.Fades(propertyValue)
  log:trace("OPC.Fades('%s')", propertyValue)
  adapter:setFades(propertyValue)
end
