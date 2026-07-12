--- Shim layer to replace Control4-specific functions with native Lua equivalents
--- for debugging and testing outside the Control4 environment.
---
--- When luasocket is available, provides full networking and timer support.
--- Without luasocket, provides stubs sufficient for module loading and static analysis.

-- Try to load luasocket (optional dependency)
local has_socket, socket = pcall(require, "socket")

-- Lua 5.2+ compatibility: loadstring was removed in favor of load
if not loadstring then
  loadstring = load
end

-- Global C4 object shim
C4 = {}
Properties = {}

-- Stub C4 functions that are called but not needed for testing
function C4:GetDriverConfigInfo()
  return nil
end
function C4:GetDeviceID()
  return 12345
end
function C4:GetDeviceData(deviceId, key)
  if key == "name" then
    return "Test Device"
  end
  return nil
end
function C4:AllowExecute() end
function C4:UpdateProperty() end
function C4:SetPropertyAttribs() end
function C4:GetVersionInfo()
  return { version = "test" }
end
function C4:FileSetDir() end
function C4:SendToDevice() end
function C4:SendToProxy() end
function C4:SendToNetwork() end
function C4:SendUIRequest()
  return ""
end
function C4:GetBindingsByDevice()
  return {}
end
function C4:FileExists()
  return false
end
function C4:FileOpen()
  return nil
end
function C4:FileGetSize()
  return 0
end
function C4:FileSetPos() end
function C4:FileRead()
  return ""
end
function C4:FileClose() end
function C4:FileDelete() end
function C4:FileWrite()
  return 0
end

--- Logging functions for C4 compatibility
function C4:ErrorLog(message)
  io.stderr:write(message .. "\n")
  io.stderr:flush()
end

function C4:DebugLog(message)
  print(message)
end

--- Base64 encoding/decoding
local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode_impl(data)
  if type(data) ~= "string" then
    return nil
  end
  return (
    (data:gsub(".", function(x)
      local r, b = "", x:byte()
      for i = 8, 1, -1 do
        r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
      if #x < 6 then
        return ""
      end
      local c = 0
      for i = 1, 6 do
        c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
      end
      return base64_chars:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1]
  )
end

local function base64_decode_impl(data)
  if type(data) ~= "string" then
    error("Invalid base64 data type")
  end
  data = string.gsub(data, "[^" .. base64_chars .. "=]", "")
  return (
    data
      :gsub(".", function(x)
        if x == "=" then
          return ""
        end
        local r, f = "", (base64_chars:find(x) - 1)
        for i = 6, 1, -1 do
          r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return r
      end)
      :gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then
          return ""
        end
        local c = 0
        for i = 1, 8 do
          c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
        end
        return string.char(c)
      end)
  )
end

-- Handle both C4:Base64Encode() and C4.Base64Encode(C4, ...) calling styles
function C4:Base64Encode(data, ...)
  if type(data) == "table" and data == C4 then
    local realData = select(1, ...)
    return base64_encode_impl(realData)
  else
    return base64_encode_impl(data)
  end
end

-- Handle both C4:Base64Decode() and C4.Base64Decode(C4, ...) calling styles
function C4:Base64Decode(data, ...)
  -- If called as C4.Base64Decode(C4, data), first arg is C4
  -- If called as C4:Base64Decode(data), first arg is data
  if type(data) == "table" and data == C4 then
    -- Called as C4.Base64Decode(C4, data) - get the real data argument
    local realData = select(1, ...)
    return base64_decode_impl(realData)
  else
    -- Called as C4:Base64Decode(data)
    return base64_decode_impl(data)
  end
end

--- Generate a UUID (simplified version)
local uuid_counter = 0
function C4:UUID(prefix)
  uuid_counter = uuid_counter + 1
  return string.format("%s-%d-%d", prefix or "UUID", os.time(), uuid_counter)
end

-- Persistence stubs (in-memory storage for testing)
local persist_store = {}

function PersistGetValue(key, encrypted)
  return persist_store[key]
end

function PersistSetValue(key, value, encrypted)
  persist_store[key] = value
end

function PersistDeleteValue(key)
  persist_store[key] = nil
end

---------------------------------------------------------------------------
-- Socket-dependent features (timers, TCP client, event loop)
-- Only available when luasocket is installed.
---------------------------------------------------------------------------

if has_socket then
  --- Timer implementation using socket.gettime
  local timers = {}
  local timer_id = 0

  function C4:SetTimer(delay_ms, callback, repeating)
    timer_id = timer_id + 1
    local id = timer_id

    local handle = {
      id = id,
      Cancel = function(self)
        if timers[id] then
          timers[id].cancelled = true
          timers[id] = nil
        end
      end,
    }

    local timer = {
      id = id,
      delay = delay_ms / 1000,
      callback = callback,
      repeating = repeating or false,
      next_fire = socket.gettime() + (delay_ms / 1000),
      cancelled = false,
      handle = handle,
    }

    timers[id] = timer
    return handle
  end

  function C4:ProcessTimers()
    local now = socket.gettime()
    for id, timer in pairs(timers) do
      if not timer.cancelled and now >= timer.next_fire then
        timer.callback(timer.handle, 0)
        if timer.repeating then
          timer.next_fire = now + timer.delay
        else
          timers[id] = nil
        end
      end
    end
  end

  --- TCP Client implementation
  local TCPClient = {}
  TCPClient.__index = TCPClient

  local active_clients = {}
  local client_id_counter = 0

  function C4:CreateTCPClient()
    client_id_counter = client_id_counter + 1
    local client = {
      id = client_id_counter,
      socket = nil,
      on_connect = nil,
      on_disconnect = nil,
      on_error = nil,
      on_read = nil,
      connected = false,
    }
    setmetatable(client, TCPClient)
    active_clients[client.id] = client
    return client
  end

  function TCPClient:OnConnect(callback)
    self.on_connect = callback
    return self
  end

  function TCPClient:OnDisconnect(callback)
    self.on_disconnect = callback
    return self
  end

  function TCPClient:OnError(callback)
    self.on_error = callback
    return self
  end

  function TCPClient:OnRead(callback)
    self.on_read = callback
    return self
  end

  function TCPClient:Connect(host, port)
    self.socket = socket.tcp()
    if not self.socket then
      if self.on_error then
        self.on_error(self, -1, "Failed to create socket")
      end
      return nil
    end

    self.socket:settimeout(5)
    local success, err = self.socket:connect(host, port)

    if not success then
      if self.on_error then
        self.on_error(self, -1, err or "Connection failed")
      end
      return nil
    end

    self.socket:settimeout(0)
    self.connected = true

    if self.on_connect then
      C4:SetTimer(10, function()
        if self.on_connect then
          self.on_connect(self)
        end
      end, false)
    end

    return self
  end

  function TCPClient:Close()
    if self.socket then
      self.socket:close()
      self.socket = nil
    end
    self.connected = false
    if self.id then
      active_clients[self.id] = nil
    end
    if self.on_disconnect then
      self.on_disconnect(self)
    end
  end

  function TCPClient:Write(data)
    if not self.socket then
      return false
    end
    local sent, err = self.socket:send(data)
    if not sent then
      if self.on_error then
        self.on_error(self, -1, err or "Write failed")
      end
      return false
    end
    return true
  end

  function TCPClient:ReadUpTo(max_bytes)
    if not self.socket then
      return
    end
    self.want_read = true
    self.max_read_bytes = max_bytes
  end

  function TCPClient:DoRead()
    if not self.socket or not self.want_read then
      return
    end
    local data, err, partial = self.socket:receive(self.max_read_bytes or 4096)
    if data and #data > 0 then
      if self.on_read then
        self.on_read(self, data)
      end
    elseif partial and #partial > 0 then
      if self.on_read then
        self.on_read(self, partial)
      end
    elseif err and err ~= "timeout" and err ~= "wantread" then
      if self.on_error then
        self.on_error(self, -1, err)
      end
      self:Close()
    end
  end

  function sleep(seconds)
    socket.sleep(seconds)
  end

  function processEventLoop()
    C4:ProcessTimers()
    for _, client in pairs(active_clients) do
      if client.DoRead then
        client:DoRead()
      end
    end
  end

  --- Run the event loop until os.exit() or signal.
  function runEventLoop()
    while true do
      processEventLoop()
      socket.sleep(0.01)
    end
  end
else
  -- Stub timer that does nothing (sufficient for module loading)
  function C4:SetTimer(delay_ms, callback, repeating)
    return { Cancel = function() end }
  end

  function C4:ProcessTimers() end
  function C4:CreateTCPClient()
    return setmetatable({}, {
      __index = function()
        return function() end
      end,
    })
  end

  function sleep() end
  function processEventLoop() end
  function runEventLoop() end
end

---------------------------------------------------------------------------
-- Crypto (C4:Hash, C4:Encrypt, C4:Decrypt)
-- Backed by CommonCrypto (macOS) or libcrypto (Linux) via LuaJIT FFI.
-- Unavailable under plain Lua (gen-squishy); calls then return nil + error.
---------------------------------------------------------------------------

local has_ffi, ffi = pcall(require, "ffi")
local crypto_backend = nil

if has_ffi then
  if ffi.os == "OSX" then
    local ok = pcall(function()
      ffi.cdef([[
        unsigned char *CC_MD5(const void *data, uint32_t len, unsigned char *md);
        unsigned char *CC_SHA1(const void *data, uint32_t len, unsigned char *md);
        unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *md);
        int CCCrypt(uint32_t op, uint32_t alg, uint32_t options,
                    const void *key, size_t keyLength, const void *iv,
                    const void *dataIn, size_t dataInLength,
                    void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved);
      ]])
    end)
    if ok then
      local C = ffi.C
      local digests = {
        MD5 = { fn = C.CC_MD5, len = 16 },
        SHA1 = { fn = C.CC_SHA1, len = 20 },
        SHA256 = { fn = C.CC_SHA256, len = 32 },
      }
      crypto_backend = {
        hash = function(algorithm, data)
          local digest = digests[string.upper(algorithm)]
          if not digest then
            return nil, "unsupported hash: " .. tostring(algorithm)
          end
          local buf = ffi.new("unsigned char[?]", digest.len)
          digest.fn(data, #data, buf)
          return ffi.string(buf, digest.len)
        end,
        -- AES-128-CBC with PKCS7 padding (kCCAlgorithmAES128=0, kCCOptionPKCS7Padding=1)
        aes128cbc = function(encrypt, key, iv, data)
          local outLen = #data + 16
          local buf = ffi.new("unsigned char[?]", outLen)
          local moved = ffi.new("size_t[1]")
          local status = C.CCCrypt(encrypt and 0 or 1, 0, 1, key, 16, iv, data, #data, buf, outLen, moved)
          if status ~= 0 then
            return nil, "CCCrypt failed: " .. tonumber(status)
          end
          return ffi.string(buf, tonumber(moved[0]))
        end,
      }
    end
  else
    local ok, libcrypto = pcall(ffi.load, "crypto")
    if ok then
      local declared = pcall(function()
        ffi.cdef([[
          unsigned char *MD5(const unsigned char *d, size_t n, unsigned char *md);
          unsigned char *SHA1(const unsigned char *d, size_t n, unsigned char *md);
          unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);
          typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
          const void *EVP_aes_128_cbc(void);
          EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
          void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
          int EVP_CipherInit_ex(EVP_CIPHER_CTX *ctx, const void *cipher, void *impl,
                                const unsigned char *key, const unsigned char *iv, int enc);
          int EVP_CipherUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
                               const unsigned char *in, int inl);
          int EVP_CipherFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
        ]])
      end)
      if declared then
        local digests = {
          MD5 = { fn = libcrypto.MD5, len = 16 },
          SHA1 = { fn = libcrypto.SHA1, len = 20 },
          SHA256 = { fn = libcrypto.SHA256, len = 32 },
        }
        crypto_backend = {
          hash = function(algorithm, data)
            local digest = digests[string.upper(algorithm)]
            if not digest then
              return nil, "unsupported hash: " .. tostring(algorithm)
            end
            local buf = ffi.new("unsigned char[?]", digest.len)
            digest.fn(data, #data, buf)
            return ffi.string(buf, digest.len)
          end,
          aes128cbc = function(encrypt, key, iv, data)
            local ctx = libcrypto.EVP_CIPHER_CTX_new()
            if ctx == nil then
              return nil, "EVP_CIPHER_CTX_new failed"
            end
            local out = ffi.new("unsigned char[?]", #data + 16)
            local outl = ffi.new("int[1]")
            local finl = ffi.new("int[1]")
            local result = nil
            if libcrypto.EVP_CipherInit_ex(ctx, libcrypto.EVP_aes_128_cbc(), nil, key, iv, encrypt and 1 or 0) == 1 then
              if libcrypto.EVP_CipherUpdate(ctx, out, outl, data, #data) == 1 then
                if libcrypto.EVP_CipherFinal_ex(ctx, out + outl[0], finl) == 1 then
                  result = ffi.string(out, outl[0] + finl[0])
                end
              end
            end
            libcrypto.EVP_CIPHER_CTX_free(ctx)
            if not result then
              return nil, "EVP cipher failed"
            end
            return result
          end,
        }
      end
    end
  end
end

local function to_hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02X", c:byte())
  end))
end

--- C4:Hash(algorithm, data, options) — supports raw ("NONE") and hex returns.
function C4:Hash(algorithm, data, options)
  if not crypto_backend then
    return nil, "C4 shim: no crypto backend (requires LuaJIT + CommonCrypto/libcrypto)"
  end
  local raw, err = crypto_backend.hash(algorithm, data or "")
  if not raw then
    return nil, err
  end
  if type(options) == "table" and string.upper(options.return_encoding or "") == "NONE" then
    return raw
  end
  return to_hex(raw)
end

local function aes_options_ok(cipher, key, iv)
  return string.upper(cipher or "") == "AES-128-CBC" and type(key) == "string" and #key == 16 and type(iv) == "string"
end

--- C4:Encrypt(cipher, key, iv, data, options) — AES-128-CBC/PKCS7, raw in/out.
function C4:Encrypt(cipher, key, iv, data, options)
  if not crypto_backend then
    return nil, "C4 shim: no crypto backend"
  end
  if not aes_options_ok(cipher, key, iv) then
    return nil, "C4 shim: only raw AES-128-CBC is supported"
  end
  return crypto_backend.aes128cbc(true, key, iv, data or "")
end

--- C4:Decrypt(cipher, key, iv, data, options) — AES-128-CBC/PKCS7, raw in/out.
function C4:Decrypt(cipher, key, iv, data, options)
  if not crypto_backend then
    return nil, "C4 shim: no crypto backend"
  end
  if not aes_options_ok(cipher, key, iv) then
    return nil, "C4 shim: only raw AES-128-CBC is supported"
  end
  return crypto_backend.aes128cbc(false, key, iv, data or "")
end

---------------------------------------------------------------------------
-- urlDo (HTTP client used by lib/http.lua)
-- Synchronous implementation over luasocket. Tests can override the global
-- with a fake (e.g. an in-process KLAP device) before loading modules.
---------------------------------------------------------------------------

if has_socket then
  local http_client = require("socket.http")
  local ltn12 = require("ltn12")

  function urlDo(method, url, data, headers, callback, context, options)
    local chunks = {}
    local requestHeaders = {}
    for name, value in pairs(headers or {}) do
      requestHeaders[name] = value
    end
    if data and #data > 0 then
      requestHeaders["content-length"] = tostring(#data)
    end
    http_client.TIMEOUT = (type(options) == "table" and tonumber(options.timeout)) or 30
    local ok, code, responseHeaders = http_client.request({
      method = method,
      url = url,
      headers = requestHeaders,
      source = data and ltn12.source.string(data) or nil,
      sink = ltn12.sink.table(chunks),
    })
    local body = table.concat(chunks)
    if not ok then
      callback(tostring(code or "request failed"), 0, {}, "", nil, url)
    else
      callback(nil, tonumber(code) or 0, responseHeaders or {}, body, nil, url)
    end
  end
end

print("C4 shim layer loaded" .. (has_socket and " (with luasocket)" or " (stubs only)"))

return C4
