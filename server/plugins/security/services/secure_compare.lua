local random = require("resty.random")

local M = {}

-- Stable for the life of this nginx worker process; never persisted or
-- exposed. Only needs internal consistency within a single comparison
-- (both operands are hashed with the same key in the same call).
local PROCESS_KEY = random.bytes(32, true) or (tostring(ngx.now()) .. tostring(ngx.worker.pid()))

-- Constant-time-ish equality check for two strings (passwords, hex secret
-- digests, etc). Comparing raw strings with `==`/`~=` is not safe: Lua
-- string equality can short-circuit on the first differing byte and also
-- leaks length via early return. HMAC-ing both sides first normalizes both
-- to a fixed-length digest before comparing, so there's no exploitable
-- relationship between comparison timing and the original secret.
function M.equals(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  return ngx.hmac_sha1(PROCESS_KEY, a) == ngx.hmac_sha1(PROCESS_KEY, b)
end

return M
