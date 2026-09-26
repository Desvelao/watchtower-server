-- OpenResty-native counterpart to pling's own
-- pling.notifiers.webhook_transport (LuaSocket/LuaSec-based) - that
-- one works fine for the standalone worker (a plain Lua 5.1 process, no
-- nginx) but cannot run inside an nginx worker process: ngx_lua breaks
-- LuaSocket's real, blocking socket.tcp() there by design (a blocking OS
-- socket call would stall the whole single-threaded worker event loop),
-- so LuaSec's ssl.https raises "Function tcp() not available from LuaSec"
-- the moment it's invoked inside ngx.timer - exactly the context the
-- embedded worker's "deliver" role tick runs in (see
-- server/workers/observe_pending_worker.lua's poll_pending_notify_batch).
-- lua-resty-http is the cosocket-based (ngx.socket.tcp) client OpenResty
-- apps use instead.
--
-- Duck-types the exact same {send(self, url, payload, headers, method)}
-- interface pling's webhook_transport.lua exposes (see
-- shared/watchtower_worker_core/notification_senders.lua's M.new(transport)), so it's a drop-in
-- replacement injected only for the embedded runtime - the standalone
-- worker keeps using pling's own transport unchanged.
local http = require("resty.http")
local cjson_safe = require("cjson.safe")

local M = {}

function M.new(opts)
  opts = opts or {}
  local instance = {
    timeout_ms = (opts.timeout or 10) * 1000,
  }
  return setmetatable(instance, { __index = M })
end

function M:send(url, payload, headers, method)
  if not url or url == "" then
    return false, "url was not provided"
  end
  method = method or "POST"

  local body, encode_err = cjson_safe.encode(payload)
  if not body then
    return false, "failed to encode payload: " .. tostring(encode_err)
  end

  local req_headers = { ["Content-Type"] = "application/json" }
  for k, v in pairs(headers or {}) do
    req_headers[k] = v
  end

  local httpc = http.new()
  httpc:set_timeout(self.timeout_ms)

  local res, err = httpc:request_uri(url, {
    method = method,
    body = body,
    headers = req_headers,
    ssl_verify = true,
  })

  if not res then
    ngx.log(ngx.ERR, string.format("webhook request to %s failed: %s", url, tostring(err)))
    return false, tostring(err)
  end

  if res.status < 200 or res.status >= 300 then
    ngx.log(
      ngx.ERR,
      string.format("webhook request to %s returned status %s: %s", url, tostring(res.status), tostring(res.body))
    )
    return false, "http status " .. tostring(res.status)
  end

  ngx.log(
    ngx.INFO,
    string.format("webhook request to %s succeeded: status=%s body=%s", url, tostring(res.status), tostring(res.body))
  )
  return true
end

return M
