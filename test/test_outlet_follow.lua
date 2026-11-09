--- The TP-Link Outlet driver follows its device: to a new protocol when a
--- firmware update, a rollback or a reset changes it, and to a new address
--- when DHCP moves it. It controls nothing that answers at the address with
--- another MAC, and a hand edit of IP Address follows whatever answers there.
---
--- The network is a stand-in: each device has an address, a MAC and the
--- protocol it speaks, and a transport reaches the device at the address it
--- is configured with. The controller's server and broadcast calls are
--- stand-ins too; a test hands the listener what the devices send back.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_follow.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local cipher = require("tplink.kasa-cipher")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

local PLUG = { mac = "02-00-00-00-00-0A", protocol = "legacy", relay = 0 }
local OTHER = { mac = "02-00-00-00-00-0B", protocol = "legacy", relay = 1 }

--- Devices by address, and each relay state set, as { address, state }.
local network = { ["192.0.2.10"] = PLUG }
local switched = {}

local Transport = {}
Transport.__index = Transport

function Transport:configure(config)
  if config.ip ~= self.ip then
    self.ip = config.ip
    self.session = false
  end
end

function Transport:reset()
  self.session = false
end

function Transport:connect()
  local device = network[self.ip]
  if self.kind == "klap" and device ~= nil and device.protocol == "klap" then
    self.session = true
    return deferred.new():resolve()
  end
  return deferred.new():reject({ error = "KLAP: no answer" })
end

function Transport:request(request)
  local device = network[self.ip]
  local reached = device ~= nil
    and ((self.kind == "legacy" and device.protocol == "legacy") or (self.session and device.protocol == "klap"))
  if not reached then
    return deferred.new():reject({ error = "no answer" })
  end
  if request.method == "get_device_info" then
    -- Not a SMART device: the driver goes on to the Kasa command set.
    return deferred.new():resolve({ error_code = -1 })
  end
  local set = Select(request, "system", "set_relay_state")
  if set then
    device.relay = set.state
    switched[#switched + 1] = { self.ip, set.state }
    return deferred.new():resolve({ system = { set_relay_state = { err_code = 0 } } })
  end
  if Select(request, "system", "get_sysinfo") then
    return deferred.new():resolve({
      system = {
        get_sysinfo = {
          err_code = 0,
          model = "ZX100(US)",
          alias = "Lamp",
          mac = device.mac,
          relay_state = device.relay,
        },
      },
    })
  end
  return deferred.new():resolve({})
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

--- Listeners open, by port, and the broadcasts sent.
local servers, broadcasts = {}, 0

function C4:CreateServer(port, _, _, identifier)
  servers[port] = identifier
  return true
end

function C4:DestroyServer(port)
  servers[port] = nil
end

function C4:SendBroadcast()
  broadcasts = broadcasts + 1
end

function C4:GetVersionInfo()
  return { version = "4.3.0.766029-res" }
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
function C4:GetProjectProperty()
  return "000000"
end

Properties = {
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["IP Address"] = "192.0.2.10",
  ["Protocol"] = "Auto",
  ["TP-Link Username"] = "user@example.com",
  ["TP-Link Password"] = "not-a-password",
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

--- Every device on the network answers the open listener, each on the port of
--- the protocol it speaks.
local function devicesAnswer()
  local _, identifier = next(servers)
  for address, device in pairs(network) do
    if device.protocol == "legacy" then
      local sysinfo = { system = { get_sysinfo = { mac = device.mac } } }
      OnServerDataIn(1, cipher.scramble(JSON:encode(sysinfo)), address, "9999", identifier)
    else
      local json = JSON:encode({ error_code = 0, result = { mac = device.mac } })
      OnServerDataIn(1, string.rep("\0", 16) .. json, address, "20002", identifier)
    end
  end
end

--- Polls the device n times, as its poll timer does.
local function poll(n)
  for _ = 1, n do
    EC.RefreshNow()
  end
end

T.section("the driver learns the device's MAC when it connects")
do
  T.eq("connected", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("its MAC kept", require("lib.persist"):get("discovery_mac"), "02:00:00:00:00:0A")
end

T.section("a restart keeps the device's MAC")
do
  ShimRestartDirector()
  dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
  ShimLateInit()
  T.eq("kept", require("lib.persist"):get("discovery_mac"), "02:00:00:00:00:0A")
  T.eq("and the device connects", Properties["Driver Status"], "Connected (Legacy)")
end

T.section("a firmware update that moves the device to KLAP is followed")
do
  PLUG.protocol = "klap"
  poll(2)
  T.eq("two missed polls mark it disconnected", Properties["Driver Status"], "Disconnected: no answer")
  poll(1)
  ShimFireTimers()
  T.eq("the third detects its protocol again", Properties["Driver Status"], "Connected (KLAP)")
  T.eq("with no search for its address", broadcasts, 0)
end

T.section("a rollback to the legacy protocol is followed")
do
  PLUG.protocol = "legacy"
  poll(3)
  ShimFireTimers()
  T.eq("connected again", Properties["Driver Status"], "Connected (Legacy)")
end

T.section("a device DHCP moves to a new address is found there by its MAC")
do
  network["192.0.2.10"], network["192.0.2.20"] = nil, PLUG
  poll(3)
  ShimFireTimers()
  T.truthy("detection at the old address fails and a search starts", next(servers))
  devicesAnswer()
  T.eq("IP Address follows the device", Properties["IP Address"], "192.0.2.20")
  T.eq("and it connects there", Properties["Driver Status"], "Connected (Legacy)")
  EC.Turn_Output_On({ Output = "1" })
  T.eq("commands go to the new address", switched, { { "192.0.2.20", 1 } })
  switched = {}
end

T.section("another device at the address is not controlled, and the device is looked for")
do
  network["192.0.2.20"] = OTHER
  poll(1)
  T.eq("Driver Status says so", Properties["Driver Status"], "Looking for the device on the network...")
  EC.Turn_Output_Off({ Output = "1" })
  T.eq("a command reaches neither device", switched, {})
  devicesAnswer()
  T.eq("its answer is not taken for the device's", Properties["IP Address"], "192.0.2.20")
  for _ = 1, 4 do
    ShimFireTimers()
  end
  T.eq(
    "with the search over, the reason shows",
    Properties["Driver Status"],
    "Disconnected: a different device is at 192.0.2.20; looking for this one"
  )
  network["192.0.2.30"] = PLUG
  ShimFireTimers()
  devicesAnswer()
  T.eq("the device found again later", Properties["IP Address"], "192.0.2.30")
  T.eq("connected", Properties["Driver Status"], "Connected (Legacy)")
end

T.section("a hand edit of IP Address follows whatever device answers there")
do
  Properties["IP Address"] = "192.0.2.20"
  OnPropertyChanged("IP Address")
  T.eq("the other device is taken", Properties["Driver Status"], "Connected (Legacy)")
  T.eq("and its MAC kept", require("lib.persist"):get("discovery_mac"), "02:00:00:00:00:0B")
  EC.Turn_Output_Off({ Output = "1" })
  T.eq("and controlled", switched, { { "192.0.2.20", 0 } })
end

T.finish()
