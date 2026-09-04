local DEFAULT_CALLS_PER_MINUTE = 60

local M = {}

function M.new(config)
  local _config = config or {}
  local instance = {
    config = {
      calls_per_minute = _config.calls_per_minute or DEFAULT_CALLS_PER_MINUTE,
    },
  }
  return setmetatable(instance, { __index = M })
end

function M:with(override_calls_per_minute)
  return function(fn)
    return function(that)
      local remaining
      local ok, err = pcall(function()
        local client_ip = that.req.remote_addr or "unknown"
        local can_call
        can_call, remaining = self:check(client_ip, override_calls_per_minute)
        if not can_call then
          error(
            "Rate limit exceeded. Allowed calls per minute: "
              .. self.config.calls_per_minute
              .. ". Try again in "
              .. remaining
              .. " seconds."
          )
        end
      end)
      if not ok then
        return {
          status = 429,
          headers = { ["Retry-After"] = tostring(remaining) },
          json = {
            error = err,
          },
        }
      end
      return fn(that)
    end
  end
end

function M:check(key, override_calls_per_minute)
  local now = os.time()
  local calls_per_minute = override_calls_per_minute
    or self.config.calls_per_minute

  -- Use ngx.shared for cross-request persistence
  local shared = ngx.shared.rate_limit_store

  if not shared then
    -- Fallback: shared memory not available, allow request
    return true, calls_per_minute
  end

  -- Store window data as "key:window" and "key:count"
  local window_key = key .. ":window"
  local count_key = key .. ":count"

  local window_start = shared:get(window_key)
  local call_count = shared:get(count_key) or 0

  -- Check if we're in a new minute window (60 seconds)
  if not window_start or (now - window_start) >= 60 then
    -- Reset window
    shared:set(window_key, now)
    shared:set(count_key, 1)
    return true, calls_per_minute - 1
  end

  -- We're in the same window
  if call_count >= calls_per_minute then
    -- Rate limit exceeded
    local remaining = 60 - (now - window_start)
    return false, remaining
  end

  -- Increment call count
  shared:incr(count_key, 1)
  return true, calls_per_minute - (call_count + 1)
end

return M
