--- Legacy Kasa transport: XOR-scrambled JSON over UDP port 9999.
---
--- This is the original TP-Link Smart Home protocol used by Kasa devices
--- before the KLAP firmware rollout (late 2024). The payload schema is the
--- same legacy IOT JSON that KLAP devices use; only the transport differs,
--- so the two transports are interchangeable behind `request(payload)`.
---
--- The "encryption" is a rolling XOR autokey cipher (initial key 171):
--- each ciphertext byte becomes the key for the next byte.
---
--- Requests are serialized FIFO with a per-request timeout, since the
--- protocol has no request/response correlation ids.

local deferred = require("deferred")

local log = require("lib.logging")

--- @class Legacy
--- @field _ip string Device IP address.
--- @field _connected boolean Whether the network binding is set up.
--- @field _queue { payload: table, d: table }[] Pending requests (FIFO).
--- @field _inFlight { payload: table, d: table }? The request awaiting a response.
local Legacy = {}
Legacy.__index = Legacy

--- Dynamic network binding id used for the UDP connection.
--- @type number
local NETWORK_BINDING = 6001

--- Kasa legacy protocol port.
--- @type number
local PORT = 9999

--- Per-request timeout in milliseconds.
--- @type number
local REQUEST_TIMEOUT_MS = 5000

--- Timer id for the in-flight request timeout.
--- @type string
local TIMEOUT_TIMER = "LegacyRequestTimeout"

--- LuaJIT bit library (available in the DriverWorks runtime).
local bit = require("bit")

--- Scrambles plaintext with the Kasa rolling XOR cipher.
--- @param plaintext string
--- @return string
local function scramble(plaintext)
  local key = 171
  local out = {}
  for i = 1, #plaintext do
    key = bit.bxor(key, plaintext:byte(i))
    out[i] = string.char(key)
  end
  return table.concat(out)
end

--- Unscrambles a Kasa rolling-XOR ciphertext.
--- @param data string
--- @return string
local function unscramble(data)
  local key = 171
  local out = {}
  for i = 1, #data do
    local byte = data:byte(i)
    out[i] = string.char(bit.bxor(key, byte))
    key = byte
  end
  return table.concat(out)
end

--- Creates a new Legacy transport.
--- @return Legacy
function Legacy:new()
  log:trace("Legacy:new()")
  local instance = setmetatable({}, self)
  instance._connected = false
  instance._queue = {}

  RFN[NETWORK_BINDING] = function(_, _, strData)
    instance:_onDataIn(strData)
  end

  return instance
end

--- Configures the transport. Resets the connection on change.
--- @param config { ip: string? }
function Legacy:configure(config)
  log:trace("Legacy:configure(<ip=%s>)", config.ip)
  if config.ip ~= nil and config.ip ~= self._ip then
    self._ip = config.ip
    self:reset()
  end
end

--- Tears down the network connection and fails all pending requests.
function Legacy:reset()
  log:trace("Legacy:reset()")
  if self._connected then
    C4:NetDisconnect(NETWORK_BINDING, PORT)
    self._connected = false
  end
  CancelTimer(TIMEOUT_TIMER)
  local failed = self._inFlight
  self._inFlight = nil
  if failed then
    failed.d:reject({ error = "Legacy: connection reset" })
  end
  for _, pending in ipairs(self._queue) do
    pending.d:reject({ error = "Legacy: connection reset" })
  end
  self._queue = {}
end

--- Sets up the UDP network binding to the configured IP.
--- @private
--- @return boolean ok
function Legacy:_ensureConnection()
  if self._connected then
    return true
  end
  if IsEmpty(self._ip) then
    return false
  end
  C4:CreateNetworkConnection(NETWORK_BINDING, self._ip, "UDP")
  C4:NetPortOptions(NETWORK_BINDING, PORT, "UDP", {
    AUTO_CONNECT = true,
    MONITOR_CONNECTION = false,
    KEEP_CONNECTION = true,
    KEEP_ALIVE = true,
    DELIMITER = "",
    -- Use an ephemeral source port: binding the local port to 9999 collides
    -- with anything else listening there (e.g. the Chowmain TP-Link agent's
    -- discovery server), which then swallows the device's replies.
    MIRROR_UDP_PORT = false,
    SUPPRESS_CONNECTION_EVENTS = true,
  })
  C4:NetConnect(NETWORK_BINDING, PORT, "UDP")
  self._connected = true
  return true
end

--- Handles a datagram from the device.
--- @private
--- @param strData string
function Legacy:_onDataIn(strData)
  local inFlight = self._inFlight
  if not inFlight then
    log:debug("Legacy: unsolicited datagram (%d bytes), ignoring", #strData)
    return
  end
  CancelTimer(TIMEOUT_TIMER)
  self._inFlight = nil

  local decoded = JSON:decode(unscramble(strData))
  self:_sendNext()
  if decoded == nil then
    inFlight.d:reject({ error = "Legacy: response is not valid JSON" })
  else
    inFlight.d:resolve(decoded)
  end
end

--- Transmits the next queued request, if idle.
--- @private
function Legacy:_sendNext()
  if self._inFlight or #self._queue == 0 then
    return
  end
  if not self:_ensureConnection() then
    for _, pending in ipairs(self._queue) do
      pending.d:reject({ error = "Legacy: no IP address configured" })
    end
    self._queue = {}
    return
  end

  self._inFlight = table.remove(self._queue, 1)
  C4:SendToNetwork(NETWORK_BINDING, PORT, scramble(JSON:encode(self._inFlight.payload)))

  SetTimer(TIMEOUT_TIMER, REQUEST_TIMEOUT_MS, function()
    local timedOut = self._inFlight
    self._inFlight = nil
    if timedOut then
      timedOut.d:reject({ error = "Legacy: request timed out (no response on UDP " .. PORT .. ")" })
    end
    self:_sendNext()
  end)
end

--- Sends a request payload (legacy IOT JSON schema) to the device.
--- @param payload table The JSON-encodable request payload.
--- @return Deferred<table, { error: string }>
function Legacy:request(payload)
  log:trace("Legacy:request(%s)", payload)
  local d = deferred.new()
  table.insert(self._queue, { payload = payload, d = d })
  self:_sendNext()
  return d
end

return Legacy
