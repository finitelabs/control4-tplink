--- The TP-Link Outlet driver and the TP-Link account: neither the username
--- nor the password is printed, at any log level, as either changes.
---
--- The transports are stand-ins that answer nothing.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_outlet_account.lua

local T = require("testlib")

require("c4_shim")

local deferred = require("deferred")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

local Transport = {}
Transport.__index = Transport

function Transport:configure() end

function Transport:reset() end

function Transport:connect()
  return deferred.new()
end

function Transport:request()
  return deferred.new()
end

local klap

package.loaded["lib.klap"] = {
  new = function(_, opts)
    local transport = setmetatable({}, Transport)
    if Select(opts, "authVersion") ~= 1 then
      klap = transport
    end
    return transport
  end,
}
package.loaded["lib.legacy"] = {
  new = function()
    return setmetatable({}, Transport)
  end,
}

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
  ["IP Address"] = "192.0.2.24",
  ["Protocol"] = "Auto",
  ["TP-Link Username"] = "user@example.com",
  ["TP-Link Password"] = "not-a-password",
  ["Poll Rate (Seconds)"] = "5",
}
dofile(HERE .. "/../drivers/tplink_outlet/driver.lua")
OnDriverLateInit()

--- Set a property as Composer does: the value, then the driver's handler.
local function setProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

T.section("the TP-Link username and password are printed at no log level")
do
  local log = require("lib.logging")
  local USERNAME, PASSWORD = "someone@example.com", "a-word-kept-secret"
  -- Everything on, as Log Level "6 - Ultra" with Log Mode "Print and Log".
  log:setLogLevel("6 - Ultra")
  log:setLogMode("Print and Log")
  DEBUGPRINT = true
  local _, _, out = T.capture(function()
    setProperty("TP-Link Username", USERNAME)
    setProperty("TP-Link Password", PASSWORD)
  end)
  T.contains("each change is traced", out, "OPC.TP_Link_Username(<redacted>)")
  T.excludes("without the username", out, USERNAME)
  T.excludes("or the password", out, PASSWORD)
  T.eq("and the driver connects with them", Properties["Driver Status"], "Connecting (KLAP)...")
  -- The handler library prints the value of a property whose handler raises.
  function klap:configure()
    error("no transport")
  end
  _, _, out = T.capture(function()
    setProperty("TP-Link Username", USERNAME)
    setProperty("TP-Link Password", PASSWORD)
  end)
  T.contains("a reconnect that raises is logged", out, "no transport")
  T.excludes("without the username", out, USERNAME)
  T.excludes("or the password", out, PASSWORD)
  DEBUGPRINT = false
  log:setLogLevel("3 - Info")
  log:setLogMode("Off")
end

T.finish()
