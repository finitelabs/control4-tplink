--- Finds a TP-Link device on the controller's own network by its MAC address,
--- so a driver can follow its device when DHCP gives it a new address.
---
--- Kasa and Tapo devices answer two broadcast queries: a scrambled get_sysinfo
--- on UDP 9999 (the legacy protocol) and a fixed 16-byte probe on UDP 20002
--- (KLAP and later firmware), whose answer is a 16-byte header and JSON. Both
--- answers carry the device's MAC; the sender is the device's address.
---
--- The queries go out from a listener on a port of the driver's own, which
--- C4:SendBroadcast takes as its source from OS 4.0. A UDP listener on port 0
--- never reports the port it was given, so the port is fixed per device.

local deferred = require("deferred")

local log = require("lib.logging")
local persist = require("lib.persist")
local cipher = require("lib.kasa-cipher")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")
require("lib.utils")

local Discovery = {}

--- Identifies this module's listener in OnServerDataIn.
local LISTENER_ID = "tplink-discovery"

--- The listener's port is BASE_PORT plus the device id modulo PORT_SPAN, or one
--- of the next PORT_TRIES - 1 ports when that one is taken.
local BASE_PORT = 47300
local PORT_SPAN = 500
local PORT_TRIES = 5

local LEGACY_PORT = 9999
local KLAP_PORT = 20002

--- The fixed probe TP-Link devices answer on UDP 20002.
local KLAP_QUERY = string.char(0x02, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0x46, 0x3c, 0xb5, 0xd3)
local LEGACY_QUERY = '{"system":{"get_sysinfo":{}}}'

--- A search runs in steps of STEP_MS. Each query goes out at once and at the
--- next SENDS - 1 steps, since a broadcast datagram can be lost; answers count
--- until step LISTEN_STEPS.
local STEP_MS = 1000
local SENDS = 3
local LISTEN_STEPS = 4

local STEP_TIMER = "DiscoveryStep"

--- The search under way: the MAC sought, its deferred, the listener's port.
--- @type { mac: string, d: table, port: integer }?
local search = nil

--- Whether this controller can search: C4:SendBroadcast takes a source port
--- from OS 4.0.
--- @return boolean
function Discovery.supported()
  local version = Select(C4:GetVersionInfo(), "version") or ""
  local major = tointeger(string.match(version, "^(%d+)%."))
  return major ~= nil and major >= 4
end

--- A MAC address in one spelling, AA:BB:CC:DD:EE:FF, from any of the three a
--- device uses (colons, dashes, or none).
--- @param mac any
--- @return string?
function Discovery.normalizeMac(mac)
  if type(mac) ~= "string" then
    return nil
  end
  local hex = string.upper((string.gsub(mac, "[^%x]", "")))
  if #hex ~= 12 then
    return nil
  end
  return (string.gsub(hex, "(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)", "%1:%2:%3:%4:%5:%6"))
end

--- The MAC address in a device's answer to one of the queries.
--- @param data string The datagram.
--- @param fromPort string|number The port it came from.
--- @return string? mac
function Discovery.parse(data, fromPort)
  if type(data) ~= "string" then
    return nil
  end
  local port = tointeger(fromPort)
  if port == KLAP_PORT then
    -- JSON:decode raises on text that is not JSON.
    local ok, decoded = pcall(JSON.decode, JSON, string.sub(data, 17))
    return ok and Discovery.normalizeMac(Select(decoded, "result", "mac")) or nil
  elseif port == LEGACY_PORT then
    local ok, decoded = pcall(JSON.decode, JSON, cipher.unscramble(data))
    local sysinfo = ok and Select(decoded, "system", "get_sysinfo") or nil
    return Discovery.normalizeMac(Select(sysinfo, "mac") or Select(sysinfo, "mic_mac"))
  end
  return nil
end

--- Ends the search under way with its result.
--- @param address string?
local function finish(address)
  local done = search
  if done == nil then
    return
  end
  search = nil
  CancelTimer(STEP_TIMER)
  C4:DestroyServer(done.port)
  done.d:resolve(address)
end

--- Handles an answer that reached the listener.
--- @param data string
--- @param address string
--- @param port string|number
local function onAnswer(data, address, port)
  if search == nil then
    return
  end
  local mac = Discovery.parse(data, port)
  log:trace("Discovery: %s from %s:%s", mac or "an answer with no MAC", address, port)
  if mac ~= nil and mac == search.mac then
    finish(address)
  end
end

local installed = false

--- Routes this module's listener to onAnswer, and every other server's data to
--- the handler the driver had, if any.
local function install()
  if installed then
    return
  end
  installed = true
  local previous = OnServerDataIn
  OnServerDataIn = function(nHandle, strData, strAddress, strPort, identifier)
    if identifier == LISTENER_ID or (identifier == nil and search ~= nil) then
      onAnswer(strData, strAddress, strPort)
    elseif previous ~= nil then
      previous(nHandle, strData, strAddress, strPort, identifier)
    end
  end
end

--- Opens the listener on this driver's port.
--- @return integer? port
local function listen()
  local first = BASE_PORT + (tointeger(C4:GetDeviceID()) or 0) % PORT_SPAN
  for port = first, first + PORT_TRIES - 1 do
    local ok, err = C4:CreateServer(port, "", true, LISTENER_ID)
    if ok then
      return port
    end
    log:debug("Discovery: no listener on port %s: %s", port, err)
  end
  return nil
end

--- Looks for the device with this MAC on the controller's network.
--- @param mac string
--- @return Deferred<string?> The device's address, or nil when it did not answer.
function Discovery.find(mac)
  local want = Discovery.normalizeMac(mac)
  if search ~= nil and search.mac == want then
    return search.d
  end
  finish(nil)
  local d = deferred.new()
  if want == nil or not Discovery.supported() then
    return d:resolve(nil)
  end
  install()
  local port = listen()
  if port == nil then
    log:warn("Discovery: no free port to listen on")
    return d:resolve(nil)
  end
  search = { mac = want, d = d, port = port }
  local legacyQuery = cipher.scramble(LEGACY_QUERY)
  local function send()
    C4:SendBroadcast(KLAP_QUERY, KLAP_PORT, port)
    C4:SendBroadcast(legacyQuery, LEGACY_PORT, port)
  end
  local step = 0
  SetTimer(STEP_TIMER, STEP_MS, function()
    if search == nil or search.d ~= d then
      return
    end
    step = step + 1
    if step >= LISTEN_STEPS then
      finish(nil)
    elseif step < SENDS then
      send()
    end
  end, true)
  send()
  return d
end

--- Ends any search under way, finding nothing.
function Discovery.stop()
  finish(nil)
end

---------------------------------------------------------------------------
-- Follower
---------------------------------------------------------------------------

--- The device's MAC address, learned the first time it answers.
local P_MAC = "discovery_mac"

--- Seconds between searches while the device stays lost: the first search is
--- at once, then these, the last repeating.
local RETRY_SECONDS = { 30, 60, 120, 300 }
local RETRY_TIMER = "DiscoveryRetry"

local LOOKING_STATUS = "Looking for the device on the network..."

--- Follows one device across address changes by its MAC address.
--- @class Follower
--- @field _onMoved fun(address: string)
--- @field _tries integer Searches since the device was lost.
--- @field _pending boolean A search is under way or scheduled.
local Follower = {}
Follower.__index = Follower

--- @param onMoved fun(address: string) Given the device's address when a search
---   finds it; the driver points itself there and connects.
--- @return Follower
function Discovery.follower(onMoved)
  return setmetatable({ _onMoved = onMoved, _tries = 0, _pending = false }, Follower)
end

--- The followed device's MAC address, AA:BB:CC:DD:EE:FF, if learned.
--- @return string?
function Follower:mac()
  return persist:get(P_MAC)
end

--- Whether the device that answered with this MAC is the one followed. The
--- first MAC seen is the device's from then on; an answer with none can't be
--- told apart and is taken as the device's.
--- @param mac any
--- @return boolean
function Follower:accepts(mac)
  local seen = Discovery.normalizeMac(mac)
  if seen == nil then
    return true
  end
  local known = persist:get(P_MAC)
  if known == nil then
    log:info("Following the device with MAC %s", seen)
    persist:set(P_MAC, seen)
    return true
  end
  return known == seen
end

--- The device answers: stop looking for it.
function Follower:found()
  self._tries = 0
  self._pending = false
  CancelTimer(RETRY_TIMER)
  Discovery.stop()
end

--- The device stopped answering, or another device answers at its address:
--- look for it at once, then again after each of RETRY_SECONDS until found.
--- Does nothing while a search is due, before the MAC is learned, or on an OS
--- that can't search.
function Follower:lost()
  if self._pending or persist:get(P_MAC) == nil or not Discovery.supported() then
    return
  end
  self._pending = true
  if self._tries == 0 then
    self:_look()
  else
    local seconds = RETRY_SECONDS[math.min(self._tries, #RETRY_SECONDS)]
    SetTimer(RETRY_TIMER, seconds * 1000, function()
      self:_look()
    end)
  end
end

--- Runs one search.
--- @private
function Follower:_look()
  local mac = persist:get(P_MAC)
  if mac == nil then
    self._pending = false
    return
  end
  local before = Properties["Driver Status"]
  UpdateProperty("Driver Status", LOOKING_STATUS)
  log:info("Looking for the device with MAC %s on the network", mac)
  Discovery.find(mac):next(function(address)
    if Properties["Driver Status"] == LOOKING_STATUS then
      UpdateProperty("Driver Status", before)
    end
    if not self._pending then
      return
    end
    self._pending = false
    self._tries = self._tries + 1
    if address == nil then
      log:info("The device with MAC %s did not answer", mac)
      self:lost()
      return
    end
    log:info("Found the device with MAC %s at %s", mac, address)
    self._onMoved(address)
  end)
end

--- The installer pointed the driver at an address by hand: follow whichever
--- device answers there from now on.
function Follower:forget()
  log:debug("Forgetting the followed MAC")
  persist:delete(P_MAC)
  self:found()
end

return Discovery
