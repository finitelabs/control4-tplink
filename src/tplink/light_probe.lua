--- One attempt to reach a TP-Link light directly: which protocol it speaks and
--- which schema it answers. With credentials it tries KLAP v2, then KLAP v1
--- hashing on an auth mismatch, then TPAP when KLAP is refused, then the legacy
--- port; without them the legacy port alone. Over a KLAP or TPAP session it asks
--- the SMART schema first, then the IOT bulb schema. A light found is adopted by
--- the adapter; once the adapter has started again, the attempt does nothing
--- more.

local log = require("lib.logging")
local IotBulb = require("tplink.iotbulb")
local SmartBulb = require("tplink.smartbulb")
local Tpap = require("tplink.tpap")

require("drivers-common-public.global.lib")
require("lib.utils")

--- The Protocol property.
--- @alias TplinkLightMode "Auto"|"KLAP"|"TPAP"|"Legacy"

--- The transport a schema was asked over, which says what follows when it
--- fails: KLAP's (v2 or v1), TPAP's, or the legacy port's.
--- @alias TplinkLightVia "klap"|"tpap"|"legacy"

--- Why a transport failed.
--- @class TplinkLinkError
--- @field error string?
--- @field code integer? HTTP status of a refused handshake or request.
--- @field locked integer? The light locked out logins.

--- @class TplinkLightProbe
--- @field adapter TplinkLightAdapter
--- @field generation integer The adapter's start the attempt belongs to.
--- @field retry boolean? The poll timer trying again after no light was found.
--- @field ip string
--- @field mode TplinkLightMode
--- @field hasCredentials boolean
--- @field klapReason string? The KLAP failure that led on, for the status.
--- @field klapCode integer? HTTP status of a refused KLAP handshake.
local TplinkLightProbe = {}
TplinkLightProbe.__index = TplinkLightProbe

--- @param adapter TplinkLightAdapter
--- @param retry boolean?
--- @param ip string
--- @return TplinkLightProbe
function TplinkLightProbe.new(adapter, retry, ip)
  local self = setmetatable({}, TplinkLightProbe)
  self.adapter = adapter
  self.generation = adapter.generation
  self.retry = retry
  self.ip = ip
  self.mode = Properties["Protocol"] or "Auto"
  self.hasCredentials = not IsEmpty(Properties["TP-Link Username"]) and not IsEmpty(Properties["TP-Link Password"])
  return self
end

--- Start probing as the Protocol property says.
--- @return boolean probing false when the properties leave nothing to try.
function TplinkLightProbe:start()
  if self.mode == "TPAP" then
    if not self.hasCredentials then
      self.adapter:noLight("Set the TP-Link Username and Password properties (required for TPAP)", self.retry)
      return false
    end
    self.adapter.detecting = true
    self:tryTpap()
  elseif self.mode == "KLAP" or (self.mode == "Auto" and self.hasCredentials) then
    if not self.hasCredentials then
      self.adapter:noLight("Set the TP-Link Username and Password properties (required for KLAP)", self.retry)
      return false
    end
    self.adapter.detecting = true
    self:tryKlap()
  else
    -- Legacy mode, or Auto without credentials (KL-series bulbs on original
    -- firmware need none).
    self.adapter.detecting = true
    self:tryLegacy()
  end
  return true
end

--- Whether the adapter is still on the start the attempt belongs to.
--- @return boolean
function TplinkLightProbe:live()
  return self.generation == self.adapter.generation
end

--- Say which transport is being tried. A retry says nothing: the reason the
--- last attempt failed for stays up until this one ends another way.
--- @param name string
function TplinkLightProbe:connecting(name)
  if not self.retry then
    UpdateProperty("Driver Status", "Connecting (" .. name .. ")...")
  end
end

--- End the attempt with no light found. The poll timer tries again.
--- @param reason string
function TplinkLightProbe:failed(reason)
  self.adapter.detecting = false
  self.adapter:noLight("Disconnected: " .. reason, self.retry)
  -- No protocol reached the light at its address: it may have moved.
  self.adapter.follower:lost()
end

--- Hand the adapter the schema and transport the light answered on, with its
--- first answer, unless another device answered.
--- @param schema TplinkLightSchema
--- @param bulb IotBulb? The IOT schema's mapping.
--- @param name string Transport name for Driver Status.
--- @param entity TplinkLightEntity
--- @param state TplinkLightState
--- @param mac string? The MAC address the light reported.
function TplinkLightProbe:adopt(schema, bulb, name, entity, state, mac)
  if not self.adapter.follower:accepts(mac) then
    log:warn("A device other than this light answers at %s", self.ip)
    self:failed("a different device is at " .. self.ip .. "; looking for this one")
    return
  end
  self.adapter:adopt(schema, bulb, name, entity, state)
end

--- Ask the IOT bulb schema over a transport.
--- @param transport Legacy|Klap|Tpap
--- @param name string Transport name for Driver Status.
--- @param via TplinkLightVia
function TplinkLightProbe:tryIotBulb(transport, name, via)
  local bulb = IotBulb:new(transport)
  bulb:poll():next(function(result)
    if self:live() then
      self:adopt("iot", bulb, name, result.entity, result.state, result.mac)
    end
  end, function(err)
    if self:live() then
      self:iotFailed(via, Select(err, "error") or "no response")
    end
  end)
end

--- The IOT bulb schema failed: the transport it went over says what follows.
--- @param via TplinkLightVia
--- @param reason string
function TplinkLightProbe:iotFailed(via, reason)
  if via == "legacy" then
    self:legacyFailed(reason)
  elseif via == "tpap" then
    self:tpapFailed(reason, true)
  else
    self:klapFailed(reason)
  end
end

--- Ask the SMART schema over an established KLAP v2 or TPAP session.
--- @param transport Klap|Tpap
--- @param name string Transport name for Driver Status.
--- @param via TplinkLightVia
function TplinkLightProbe:trySmart(transport, name, via)
  transport:request({ method = "get_device_info", params = {} }):next(function(response)
    if not self:live() then
      return
    end
    if tointeger(Select(response, "error_code")) == 0 then
      local info = Select(response, "result") or {}
      self.adapter.link.smart = transport
      self:adopt("smart", nil, name, SmartBulb.entity(info), SmartBulb.state(info), info.mac)
    else
      self:smartFailed(via, "device rejected get_device_info over " .. name)
    end
  end, function(err)
    if self:live() then
      self:smartFailed(via, Select(err, "error") or "SMART request failed")
    end
  end)
end

--- The SMART schema failed: the IOT bulb schema is asked over the same session.
--- @param via TplinkLightVia
--- @param reason string
function TplinkLightProbe:smartFailed(via, reason)
  if via == "tpap" then
    log:info("SMART probe failed (%s); trying IOT bulb schema over TPAP", reason)
    self:tryIotBulb(self.adapter.link.tpap, "TPAP", "tpap")
  else
    log:info("SMART probe failed (%s); trying IOT bulb schema over KLAP", reason)
    self:tryIotBulb(self.adapter.link.klap, "KLAP", "klap")
  end
end

--- Probe the legacy port 9999 transport, the last resort in Auto mode.
function TplinkLightProbe:tryLegacy()
  self:connecting("Legacy")
  self:tryIotBulb(self.adapter.link.legacy, "Legacy", "legacy")
end

--- The legacy port failed too: the attempt ends with the reasons.
--- @param legacyReason string
function TplinkLightProbe:legacyFailed(legacyReason)
  if self.klapCode == 403 then
    log:info("Legacy probe failed: %s", legacyReason)
    self:failed(self.klapReason)
    return
  end
  if self.mode == "Auto" and not self.hasCredentials then
    legacyReason = legacyReason .. " (set TP-Link credentials if this device is on KLAP firmware)"
  end
  self:failed(self.klapReason and ("KLAP: " .. self.klapReason .. " / Legacy: " .. legacyReason) or legacyReason)
end

--- Probe TPAP: ask the light whether it uses it, log in, then the SMART schema
--- and the IOT bulb schema over the session.
function TplinkLightProbe:tryTpap()
  self:connecting("TPAP")
  Tpap.discover(self.ip):next(function(info)
    if self:live() then
      self:tpapAnswered(info)
    end
  end, function(err)
    if self:live() then
      self:tpapFailed(Select(err, "error") or "no answer to TPAP discover", Select(err, "locked") ~= nil)
    end
  end)
end

--- The light answered TPAP's discover: log in if it takes a login this driver
--- supports.
--- @param info TpapInfo? nil when the light does not use TPAP.
function TplinkLightProbe:tpapAnswered(info)
  if info == nil then
    self:tpapFailed("the light does not use TPAP")
    return
  end
  if not Tpap.supports(info) then
    self:tpapFailed(
      "the light asks for a login this driver does not support yet; turn on Third-Party Compatibility in the Tapo or Kasa app",
      true
    )
    return
  end
  local tpap = self.adapter.link.tpap
  tpap:configure({ port = info.port })
  tpap:connect():next(function()
    if self:live() then
      self:trySmart(tpap, "TPAP", "tpap")
    end
  end, function(err)
    if self:live() then
      self:tpapFailed(Select(err, "error") or "TPAP login failed", true)
    end
  end)
end

--- TPAP failed. In TPAP mode, or when TPAP answered for the light and its
--- reason is the one to show, the attempt ends; after a refused KLAP handshake
--- the legacy port is tried.
--- @param reason string
--- @param final boolean?
function TplinkLightProbe:tpapFailed(reason, final)
  if self.mode == "TPAP" or final then
    self:failed(reason)
    return
  end
  log:info("TPAP probe failed (%s); trying legacy protocol", reason)
  self:tryLegacy()
end

--- Probe the KLAP transports: v2 handshake, then the SMART schema (Tapo, newer
--- Kasa), then the IOT bulb schema over the same session (KL-series on KLAP
--- firmware).
function TplinkLightProbe:tryKlap()
  self:connecting("KLAP")
  local klap = self.adapter.link.klap
  klap:connect():next(function()
    if self:live() then
      self:trySmart(klap, "SMART", "klap")
    end
  end, function(err)
    if self:live() then
      self:klapRefused(err)
    end
  end)
end

--- The KLAP v2 handshake failed. An auth mismatch tries it again with v1
--- hashing before falling back.
--- @param err TplinkLinkError
function TplinkLightProbe:klapRefused(err)
  local reason = Select(err, "error") or "KLAP connection failed"
  if string.find(reason, "auth mismatch", 1, true) == nil then
    self:klapFailed(reason, Select(err, "code"))
    return
  end
  log:info("KLAP v2 handshake failed (%s); retrying with v1 hashing", reason)
  local klapV1 = self.adapter.link.klapV1
  klapV1:connect():next(function()
    if self:live() then
      self:tryIotBulb(klapV1, "KLAP", "klap")
    end
  end, function(v1Err)
    if self:live() then
      self:klapFailed(Select(v1Err, "error") or "KLAP connection failed", Select(v1Err, "code"))
    end
  end)
end

--- KLAP failed: on to TPAP, the legacy port, or the end. A light whose account
--- has Third-Party Compatibility off refuses KLAP (403, or 500 on some light
--- strips) and takes TPAP instead.
--- @param reason string
--- @param code integer? HTTP status of a refused handshake.
function TplinkLightProbe:klapFailed(reason, code)
  self.klapReason, self.klapCode = reason, code
  if self.mode == "KLAP" then
    self:failed(reason)
  elseif code == 403 or code == 500 then
    log:info("KLAP refused (%s); trying TPAP", reason)
    self:tryTpap()
  else
    log:info("KLAP probe failed (%s); trying legacy protocol", reason)
    self:tryLegacy()
  end
end

return TplinkLightProbe
