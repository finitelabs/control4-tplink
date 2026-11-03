--- The TP-Link Outlet driver's connect attempts: one replaced by another, or a
--- poll or a write from before it, does nothing when its answer comes in, and
--- the poll timer starts no second attempt while one is probing.
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
local connects = { klap = 0, legacy = 0 }

local Transport = {}
Transport.__index = Transport

function Transport:configure(config)
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
-- Loaded unprocessed, OnDriverInit runs both sides of --#ifdef DRIVERCENTRAL.
package.loaded["cloud-client-byte"] = true

--- The oldest held request of this kind, taken off the list.
--- @param kind string "klap" or "legacy"
--- @param what? string "handshake", "smart" or "sysinfo"
local function take(kind, what)
  for i, h in ipairs(held) do
    local is = (what == "handshake" and h.request.handshake)
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

T.finish()
