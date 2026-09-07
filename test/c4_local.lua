--- Driver-local C4 environment seam for control4-tplink.
---
--- Provides the bare `urlDo` global that `lib/http.lua` calls. The shim models
--- the `C4:*` surface and the controller supplies `urlDo` alongside it, so it
--- belongs beside the shim rather than inside it: `test/c4_shim.lua` is
--- template-managed and anything local in there is merge surface on every
--- `copier update`.
---
--- Synchronous implementation over luasocket. Tests can override the global
--- with a fake (e.g. an in-process KLAP device) before loading modules, then
--- `dofile("c4_local.lua")` to put the real one back.

require("c4_shim")

-- socket.http and ltn12 are separate rocks from the socket core, and
-- c4_fixtures.lua's withShim() preloads a socket stub that supplies neither,
-- so a loadable socket core alone does not imply they are loadable.
local has_socket = pcall(require, "socket")
local has_http, http_client = pcall(require, "socket.http")
local has_ltn12, ltn12 = pcall(require, "ltn12")

if has_socket and has_http and has_ltn12 then
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
