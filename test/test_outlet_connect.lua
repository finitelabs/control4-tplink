--- The TP-Link Outlet driver's connect attempts: one replaced by another, or a
--- poll or a write from before it, does nothing when its answer comes in, the
--- poll timer starts no second attempt while one is probing, and a KLAP login
--- the device refuses goes on to TPAP.
---
--- The transports are stand-ins that hold every request until the test
--- answers it, as a device that takes its time does.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_connect.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local persist = require("lib.persist")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

--- Every request made and not yet answered, oldest first.
local held = {}

--- Handshakes begun, by transport kind.
local connects = { klap = 0, legacy = 0, tpap = 0 }

--- Times a transport was configured, as each connect attempt does.
local configures = 0

local Transport = {}
Transport.__index = Transport

function Transport:configure(config)
  configures = configures + 1
  self.ip = config.ip
end

function Transport:reset() end

--- Holds a request until the test answers it.
--- @return table d
function Transport:_hold(request)
  local d = deferred.new()
  held[#held + 1] = { kind = self.kind, ip = self.ip, request = request, d = d }
  return d
end

function Transport:connect()
  connects[self.kind] = connects[self.kind] + 1
  return self:_hold({ handshake = true })
end

function Transport:request(request)
  return self:_hold(request)
end

package.loaded["tplink.klap"] = {
  new = function()
    return setmetatable({ kind = "klap" }, Transport)
  end,
}
package.loaded["tplink.legacy"] = {
  new = function()
    return setmetatable({ kind = "legacy" }, Transport)
  end,
}
package.loaded["tplink.tpap"] = {
  new = function()
    return setmetatable({ kind = "tpap" }, Transport)
  end,
  discover = function(ip)
    local d = deferred.new()
    held[#held + 1] = { kind = "tpap", ip = ip, request = { discover = true }, d = d }
    return d
  end,
  supports = function(info)
    return info.tls == 0 and info.pake[1] == 2
  end,
}
-- Loaded unprocessed, OnDriverInit runs both sides of --#ifdef DRIVERCENTRAL.
package.loaded["cloud-client-byte"] = true

--- The oldest held request of this kind, taken off the list.
--- @param kind string "klap", "legacy" or "tpap"
--- @param what? string "handshake", "discover", "smart", "sysinfo" or "write"
local function take(kind, what)
  for i, h in ipairs(held) do
    local is = (what == "handshake" and h.request.handshake)
      or (what == "discover" and h.request.discover)
      or (what == "write" and Select(h.request, "system", "set_relay_state") ~= nil)
      or (what == "smart" and h.request.method ~= nil)
      or (what == "sysinfo" and Select(h.request, "system", "get_sysinfo") ~= nil)
      or what == nil
    if h.kind == kind and is then
      table.remove(held, i)
      return h
    end
  end
  error("nothing held for " .. kind .. " " .. tostring(what), 2)
end

--- A get_sysinfo answer from the device with this MAC.
local function sysinfo(mac, relay)
  return {
    system = {
      get_sysinfo = { err_code = 0, model = "ZX100(US)", alias = "Lamp", mac = mac, relay_state = relay or 0 },
    },
  }
end

--- The events fired, by name.
local EVENTS = { [1] = "Output 1 Turned On", [51] = "Output 1 Turned Off", [100] = "Connected", [101] = "Disconnected" }
local fired = {}
function C4:FireEventByID(id)
  fired[#fired + 1] = EVENTS[id] or id
end

-- Not an OS that can search for a lost device: this suite is about attempts.
function C4:GetVersionInfo()
  return { version = "3.3.0.0-res" }
end

local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return config(self, section)
end

function C4:UpdateProperty(name, value)
  Properties[name] = value
end

Properties = {
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["IP Address"] = "192.0.2.10",
  ["Protocol"] = "Auto",
  ["TP-Link Username"] = "",
  ["TP-Link Password"] = "",
  ["Poll Rate (Seconds)"] = "5",
  ["Energy Poll Rate (Seconds)"] = "0",
  ["Model"] = "",
  ["Device Name"] = "",
  ["MAC Address"] = "",
  ["Firmware"] = "",
  ["WiFi RSSI"] = "",
}

dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
ShimLateInit()

--- Set a property as Composer does.
local function set(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

--- Drop every held request, answered or not.
local function clear()
  for i = #held, 1, -1 do
    held[i] = nil
  end
end

--- Refuse the KLAP login held, as a device with Third-Party Compatibility off.
--- @param code? integer The HTTP status, 403 unless given.
local function refuseKlap(code)
  code = code or 403
  take("klap", "handshake").d:reject({ error = "Klap: device refused the handshake (HTTP " .. code .. ")", code = code })
end

local OFFERED = { port = 80, tls = 0, pake = { 2 } }
local REFUSED = "TPAP: the TP-Link account password was refused; change TP-Link Password to try again"

T.section("the poll timer starts no second attempt while one is probing")
do
  T.eq("the first attempt probes the legacy port", Properties["Driver Status"], "Connecting (Legacy)...")
  ShimFireTimers()
  ShimFireTimers()
  T.eq("its probe is the only one", #held, 1)
  take("legacy", "sysinfo").d:reject({ error = "no answer" })
  T.eq(
    "it fails",
    Properties["Driver Status"],
    "Disconnected: no answer (set TP-Link credentials if this device is on KLAP firmware)"
  )
  ShimFireTimers()
  T.eq("the next tick tries again", #held, 1)
  T.eq(
    "keeping the reason the last attempt failed for",
    Properties["Driver Status"],
    "Disconnected: no answer (set TP-Link credentials if this device is on KLAP firmware)"
  )
  take("legacy", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0A"))
  T.eq("and connects", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("firing Connected", fired[#fired], "Connected")
end

T.section("an attempt replaced by another does nothing when it fails")
do
  fired = {}
  set("TP-Link Username", "user@example.com")
  local first = take("legacy", "sysinfo")
  set("TP-Link Password", "not-a-password")
  T.eq("the account in full is tried over KLAP", Properties["Driver Status"], "Connecting (KLAP)...")
  take("klap", "handshake").d:resolve()
  take("klap", "smart").d:resolve({ error_code = -1 })
  take("klap", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0A"))
  T.eq("which connects", Properties["Driver Status"], "Connected (KLAP)")
  first.d:reject({ error = "Legacy: request timed out (no response on UDP 9999)" })
  T.eq("the replaced attempt's probe failing leaves it connected", Properties["Driver Status"], "Connected (KLAP)")
  T.eq("and fires nothing", fired, {})
end

T.section("a poll from before an IP Address edit does nothing when it is answered")
do
  fired = {}
  set("Protocol", "Legacy")
  take("legacy", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0A"))
  EC.RefreshNow()
  local poll = take("legacy", "sysinfo")
  set("IP Address", "192.0.2.20")
  poll.d:resolve(sysinfo("02:00:00:00:00:0A", 1))
  T.eq("the old device's answer is not taken", persist:get("discovery_mac"), nil)
  T.eq("nor its output's state", fired, {})
  local probe = take("legacy", "sysinfo")
  T.eq("the new address is probed", probe.ip, "192.0.2.20")
  probe.d:resolve(sysinfo("02:00:00:00:00:0B"))
  T.eq("and its device followed", persist:get("discovery_mac"), "02:00:00:00:00:0B")
  T.eq("connected there", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("with IP Address as it was set", Properties["IP Address"], "192.0.2.20")
end

T.section("a write from before a reconnect does nothing when it fails")
do
  fired = {}
  EC.Turn_Output_On({ Output = "1" })
  local write = take("legacy")
  EC.Reconnect()
  take("legacy", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0B"))
  write.d:reject({ error = "Legacy: connection reset" })
  T.eq("the device stays connected", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("with no event", fired, {})
end

T.section("a poll sent before a write does not undo it")
do
  clear()
  fired = {}
  EC.RefreshNow()
  local poll = take("legacy", "sysinfo")
  EC.Turn_Output_On({ Output = "1" })
  take("legacy", "write").d:resolve({ system = { set_relay_state = { err_code = 0 } } })
  T.eq("the write's answer turns the output on", fired, { "Output 1 Turned On" })
  poll.d:resolve(sysinfo("02:00:00:00:00:0B", 0))
  T.eq("the older poll's off is not taken", fired, { "Output 1 Turned On" })
  EC.RefreshNow()
  take("legacy", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0B", 1))
  T.eq("and the next poll agrees", fired, { "Output 1 Turned On" })
end

T.section("with no IP Address the poll timer does not try to connect")
do
  clear()
  set("IP Address", "")
  T.eq("it says what to set", Properties["Driver Status"], "Set the IP Address property")
  local before = configures
  ShimFireTimers()
  ShimFireTimers()
  T.eq("and tries nothing on each poll", configures, before)
  T.eq("nor sends anything", #held, 0)
  set("IP Address", "192.0.2.20")
  take("legacy", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0B"))
  T.eq("an address set connects", Properties["Driver Status"], "Connected (Legacy)")
end

T.section("a KLAP login refused with 403 or 500 goes on to TPAP, and connects over it")
do
  set("Protocol", "Auto")
  for _, code in ipairs({ 403, 500 }) do
    if code ~= 403 then
      EC.Reconnect()
    end
    refuseKlap(code)
    T.eq("HTTP " .. code .. ": TPAP is tried", Properties["Driver Status"], "Connecting (TPAP)...")
    take("tpap", "discover").d:resolve(OFFERED)
    take("tpap", "handshake").d:resolve()
    take("tpap", "smart").d:resolve({ error_code = -1 })
    take("tpap", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0B"))
    T.eq("HTTP " .. code .. ": connected over it", Properties["Driver Status"], "Connected (TPAP)")
  end
end

T.section("a device that does not use TPAP is tried on the legacy protocol")
do
  EC.Reconnect()
  refuseKlap()
  take("tpap", "discover").d:resolve(nil)
  T.eq("the legacy protocol is tried", Properties["Driver Status"], "Connecting (Legacy)...")
  take("legacy", "sysinfo").d:resolve(sysinfo("02:00:00:00:00:0B"))
  T.eq("and connects", Properties["Driver Status"], "Connected (Legacy)")
end

T.section("a login TPAP cannot make, a refused password or a lock ends the attempt with TPAP's reason")
do
  local cases = {
    {
      "a login it does not support",
      function()
        take("tpap", "discover").d:resolve({ port = 443, tls = 1, pake = { 2 } })
      end,
      "Disconnected: the device asks for a login this driver does not support yet;"
        .. " turn on Third-Party Compatibility in the Tapo or Kasa app",
    },
    {
      "a refused password",
      function()
        take("tpap", "discover").d:resolve(OFFERED)
        take("tpap", "handshake").d:reject({ error = REFUSED, refused = true })
      end,
      "Disconnected: " .. REFUSED,
    },
    {
      "a lock",
      function()
        take("tpap", "discover").d:reject({ error = "TPAP: the device is locked after failed logins", locked = 30 })
      end,
      "Disconnected: TPAP: the device is locked after failed logins",
    },
  }
  for _, case in ipairs(cases) do
    clear()
    EC.Reconnect()
    refuseKlap()
    case[2]()
    T.eq(case[1] .. ": its reason is shown", Properties["Driver Status"], case[3])
    T.eq(case[1] .. ": and no legacy probe goes out", #held, 0)
  end
end

T.section("TPAP without the account says so")
do
  clear()
  set("Protocol", "TPAP")
  take("tpap", "discover")
  set("TP-Link Password", "")
  T.eq(
    "it says what to set",
    Properties["Driver Status"],
    "Set the TP-Link Username and Password properties (required for TPAP)"
  )
  T.eq("and asks nothing", #held, 0)
  set("TP-Link Password", "not-a-password")
  set("Protocol", "Auto")
end

T.section("a TPAP probe replaced by another does nothing when it is answered")
do
  clear()
  EC.Reconnect()
  refuseKlap()
  local discover = take("tpap", "discover")
  EC.Reconnect()
  local logins = connects.tpap
  discover.d:resolve(OFFERED)
  T.eq("no login follows", connects.tpap, logins)
  T.eq("the new attempt is the one shown", Properties["Driver Status"], "Connecting (KLAP)...")
end

T.section("a probe answered after the driver is removed does nothing")
do
  clear()
  EC.Reconnect()
  local probe = take("klap", "handshake")
  OnDriverDestroyed()
  probe.d:reject({ error = "Klap: connection reset" })
  T.eq("its status is left as it was", Properties["Driver Status"], "Connecting (KLAP)...")
end

T.finish()
