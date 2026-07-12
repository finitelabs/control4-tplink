--- SMART-schema adapter for TP-Link Kasa/Tapo plugs and power strips.
---
--- Newer devices (Kasa EP25 v2.6, KP125M, EP40M, all Tapo P-series) replace
--- the legacy IOT JSON schema with the SMART schema:
--- `{"method":"get_device_info"}` style requests over a KLAP v2 session. This
--- adapter presents the same `request(payload)` interface as the Legacy and
--- Klap transports but accepts the IOT payloads the outlet driver speaks,
--- translating requests and responses so the driver stays schema-agnostic:
---
---   system.get_sysinfo     -> get_device_info (+ get_child_device_list on
---                             multi-outlet devices; children synthesized in
---                             the IOT sysinfo shape)
---   system.set_relay_state -> set_device_info   ({ device_on = bool })
---   emeter.get_realtime    -> get_energy_usage  (power_mw <- current_power)
---
--- Requests carrying an IOT child context (`context.child_ids`) are routed
--- through `control_child` with a nested multipleRequest, matching how the
--- python-kasa reference talks to strip outlets.
---
--- SMART errors surface as `err_code` in the translated response, matching
--- how IOT devices report failures.

local deferred = require("deferred")

local log = require("lib.logging")

--- @class Smart
--- @field _klap Klap The underlying KLAP transport (owned by the driver).
--- @field _childrenSupported boolean? Whether the device has child outlets
---   (nil until first probed; false caches a rejected probe).
local Smart = {}
Smart.__index = Smart

--- Creates a new Smart adapter over an existing KLAP transport.
--- The transport's configuration and session lifecycle stay with its owner.
--- @param klap Klap
--- @return Smart
function Smart:new(klap)
  log:trace("Smart:new()")
  local instance = setmetatable({}, self)
  instance._klap = klap
  return instance
end

--- Clears cached device capabilities (call when the target device may have
--- changed, e.g. on reconfiguration).
function Smart:reset()
  log:trace("Smart:reset()")
  self._childrenSupported = nil
end

--- Decodes the base64 nickname from get_device_info.
--- @param nickname any
--- @return string? nickname Decoded text, or nil if absent/undecodable.
local function decodeNickname(nickname)
  if type(nickname) ~= "string" or nickname == "" then
    return nil
  end
  local ok, decoded = pcall(C4.Base64Decode, C4, nickname)
  if ok and type(decoded) == "string" and decoded ~= "" then
    return decoded
  end
  return nil
end

--- Extracts the SMART error code from a response.
--- @param response table
--- @return number code 0 on success; -1 when the response has no error_code.
local function errorCode(response)
  return tointeger(Select(response, "error_code")) or -1
end

--- Executes one SMART method against the device or one of its children.
--- Child calls are wrapped in control_child + multipleRequest, per the
--- python-kasa reference; empty params are omitted there because the nested
--- request shape is stricter than the top-level one.
--- @private
--- @param childId string? The child device_id, or nil for the device itself.
--- @param method string
--- @param params table?
--- @return Deferred<{ code: number, result: table? }, { error: string, code: number? }>
function Smart:_call(childId, method, params)
  if childId == nil then
    return self._klap:request({ method = method, params = params or {} }):next(function(response)
      return { code = errorCode(response), result = Select(response, "result") }
    end)
  end

  local inner = { method = method }
  if params ~= nil and not IsEmpty(params) then
    inner.params = params
  end
  return self._klap
    :request({
      method = "control_child",
      params = {
        device_id = childId,
        requestData = { method = "multipleRequest", params = { requests = { inner } } },
      },
    })
    :next(function(response)
      local code = errorCode(response)
      if code ~= 0 then
        return { code = code }
      end
      local nested = Select(response, "result", "responseData", "result", "responses", 1)
      if type(nested) ~= "table" then
        return { code = -1 }
      end
      return { code = tointeger(nested.error_code) or -1, result = nested.result }
    end)
end

--- Maps a get_device_info result to the IOT get_sysinfo shape the driver reads.
--- @param info table
--- @return table sysinfo
local function toSysinfo(info)
  return {
    err_code = 0,
    model = info.model,
    alias = decodeNickname(info.nickname),
    mac = info.mac,
    sw_ver = info.fw_ver,
    hw_ver = info.hw_ver,
    rssi = info.rssi,
    relay_state = toboolean(info.device_on) and 1 or 0,
  }
end

--- Fetches all child outlets, following pagination.
--- @private
--- @param onDone fun(children: table[]?, code: number?) children in IOT shape,
---   or nil with the SMART error code when the device rejects the method.
function Smart:_fetchChildren(onDone)
  local children = {}

  local function fetchPage()
    self:_call(nil, "get_child_device_list", { start_index = #children }):next(function(reply)
      if reply.code ~= 0 then
        onDone(nil, reply.code)
        return
      end
      local page = Select(reply.result, "child_device_list")
      if type(page) ~= "table" then
        onDone(nil, -1)
        return
      end
      for _, child in ipairs(page) do
        table.insert(children, {
          id = child.device_id,
          alias = decodeNickname(child.nickname),
          state = toboolean(child.device_on) and 1 or 0,
        })
      end
      local total = tointeger(Select(reply.result, "sum")) or #children
      if #children < total and #page > 0 then
        fetchPage()
      else
        onDone(children)
      end
    end, function(err)
      onDone(nil, tointeger(Select(err, "code")) or -1)
    end)
  end

  fetchPage()
end

--- system.get_sysinfo -> get_device_info (+ children on multi-outlet devices)
--- @private
--- @return Deferred<table, { error: string, code: number? }>
function Smart:_getSysinfo()
  return self:_call(nil, "get_device_info"):next(function(reply)
    if reply.code ~= 0 then
      return { system = { get_sysinfo = { err_code = reply.code } } }
    end
    local sysinfo = toSysinfo(reply.result or {})
    if self._childrenSupported == false then
      return { system = { get_sysinfo = sysinfo } }
    end

    -- Multi-outlet devices expose their outlets as child devices. Probe once;
    -- a rejection means a single-outlet device and is cached, while a failure
    -- on a known strip is surfaced so the driver retries instead of silently
    -- collapsing to one output.
    local d = deferred.new()
    self:_fetchChildren(function(children, code)
      if children ~= nil and #children > 0 then
        self._childrenSupported = true
        sysinfo.children = children
      elseif self._childrenSupported == true then
        return d:resolve({ system = { get_sysinfo = { err_code = code or -1 } } })
      else
        self._childrenSupported = false
      end
      d:resolve({ system = { get_sysinfo = sysinfo } })
    end)
    return d
  end)
end

--- system.set_relay_state -> set_device_info
--- @private
--- @param childId string?
--- @param on boolean
--- @return Deferred<table, { error: string, code: number? }>
function Smart:_setRelayState(childId, on)
  return self:_call(childId, "set_device_info", { device_on = on }):next(function(reply)
    return { system = { set_relay_state = { err_code = reply.code } } }
  end)
end

--- emeter.get_realtime -> get_energy_usage
--- A device without energy monitoring rejects the method; the non-zero
--- err_code makes the driver disable energy polling, same as an IOT device
--- without an emeter.
--- @private
--- @param childId string?
--- @return Deferred<table, { error: string, code: number? }>
function Smart:_getRealtime(childId)
  return self:_call(childId, "get_energy_usage"):next(function(reply)
    if reply.code ~= 0 then
      return { emeter = { get_realtime = { err_code = reply.code } } }
    end
    -- current_power is milliwatts, matching the IOT hardware-v2 power_mw field.
    local currentPower = tonumber(Select(reply.result, "current_power"))
    return { emeter = { get_realtime = { err_code = 0, power_mw = currentPower or 0 } } }
  end)
end

--- Sends an IOT-schema request, translated to the SMART schema.
--- @param payload table The IOT-schema request payload.
--- @return Deferred<table, { error: string, code: number? }>
function Smart:request(payload)
  log:trace("Smart:request(%s)", payload)

  local childId = Select(payload, "context", "child_ids", 1)
  if childId ~= nil then
    childId = tostring(childId)
  end

  if Select(payload, "system", "get_sysinfo") ~= nil then
    return self:_getSysinfo()
  end
  local relay = Select(payload, "system", "set_relay_state")
  if relay ~= nil then
    return self:_setRelayState(childId, tointeger(relay.state) == 1)
  end
  if Select(payload, "emeter", "get_realtime") ~= nil then
    return self:_getRealtime(childId)
  end
  return deferred.new():reject({ error = "Smart: no SMART translation for request" })
end

return Smart
