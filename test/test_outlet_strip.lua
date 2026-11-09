--- The TP-Link Outlet driver on a power strip: each child outlet the strip
--- reports becomes an output, up to six, a command carries the child id of
--- the output it is for, and a child's state reaches only its own output.
---
--- The strip is a stand-in on the legacy port that answers at once. A strip
--- that reports short child ids takes them only with its device id in front.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_strip.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local values = require("lib.values")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

local DEVICE_ID = "8006F00D00000000000000000000000000000001"

--- The strip: its children as get_sysinfo reports them, and each request that
--- set a relay, as { child ids, state }.
local strip = { children = {}, set = {} }

local Transport = {}
Transport.__index = Transport

function Transport:configure() end

function Transport:reset() end

function Transport:connect()
  return deferred.new()
end

function Transport:request(request)
  local set = Select(request, "system", "set_relay_state")
  if set then
    local ids = Select(request, "context", "child_ids")
    strip.set[#strip.set + 1] = { ids, set.state }
    for _, c in ipairs(strip.children) do
      local full = #c.id < #DEVICE_ID and DEVICE_ID .. c.id or c.id
      if full == Select(ids, 1) then
        c.state = set.state
      end
    end
    return deferred.new():resolve({ system = { set_relay_state = { err_code = 0 } } })
  end
  if Select(request, "system", "get_sysinfo") then
    return deferred.new():resolve({
      system = {
        get_sysinfo = { err_code = 0, model = "ZX300(US)", deviceId = DEVICE_ID, children = strip.children },
      },
    })
  end
  -- No energy meter.
  return deferred.new():resolve({})
end

local function newTransport()
  return setmetatable({}, Transport)
end

package.loaded["tplink.klap"] = { new = newTransport }
package.loaded["tplink.legacy"] = { new = newTransport }
-- Loaded unprocessed, OnDriverInit runs both sides of --#ifdef DRIVERCENTRAL.
package.loaded["cloud-client-byte"] = true

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
  ["IP Address"] = "192.0.2.24",
  ["Protocol"] = "Legacy",
  ["Poll Rate (Seconds)"] = "5",
  ["Model"] = "",
  ["Device Name"] = "",
  ["MAC Address"] = "",
  ["Firmware"] = "",
  ["WiFi RSSI"] = "",
}

--- A child outlet as the strip reports it.
local function child(id, state, alias)
  return { id = id, state = state, alias = alias }
end

--- Each output's state, 1 to n.
local function states(n)
  local out = {}
  for i = 1, n do
    out[i] = Select(values:getValue("Output " .. i .. " State"), "value")
  end
  return out
end

--- The relay requests sent since the last call.
local function drain()
  local set = strip.set
  strip.set = {}
  return set
end

-- Seven children, with short ids: one more than the driver takes.
for i = 1, 7 do
  strip.children[i] = child(string.format("%02d", i - 1), i == 2 and 1 or 0, "Socket " .. i)
end

dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
ShimLateInit()

T.section("each child is an output, up to six")
do
  for n = 1, 6 do
    T.truthy("output " .. n .. " has a relay connection", bindings:getDynamicBinding("relay", "output_" .. n))
  end
  T.eq("a seventh child has none", bindings:getDynamicBinding("relay", "output_7"), nil)
  T.eq("each takes its child's name", Select(values:getValue("Output 3 Name"), "value"), "Socket 3")
  T.eq("and its state", states(6), { false, true, false, false, false, false })
end

T.section("a short child id is sent with the device id in front")
do
  EC.Turn_Output_On({ Output = "3" })
  T.eq("output 3", drain(), { { { DEVICE_ID .. "02" }, 1 } })
  T.eq("only its state changes", states(6), { false, true, true, false, false, false })
  EC.Toggle_Output({ Output = "2" })
  T.eq("a toggle of output 2", drain(), { { { DEVICE_ID .. "01" }, 0 } })
  EC.Turn_Output_On({ Output = "7" })
  T.eq("an output the driver does not have is not sent", drain(), {})
end

T.section("a full child id is sent as the strip reports it")
do
  strip.children = {
    child(DEVICE_ID .. "00", 0, "Left"),
    child(DEVICE_ID .. "01", 1, "Right"),
  }
  EC.RefreshNow()
  EC.Turn_Output_Off({ Output = "2" })
  T.eq("output 2", drain(), { { { DEVICE_ID .. "01" }, 0 } })
end

T.section("a child's state reaches only its own output")
do
  strip.children[1].state = 1
  EC.RefreshNow()
  T.eq("output 1 on, output 2 as it was", states(2), { true, false })
end

T.finish()
