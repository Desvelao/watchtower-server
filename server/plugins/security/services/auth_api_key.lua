local M = {}

local resty_sha256 = require("resty.sha256")
local resty_str = require("resty.string")
local random = require("resty.random")
local cjson_safe = require("cjson.safe")
local secure_compare = require("plugins.security.services.secure_compare")

local function hash_str(str)
  local sha256 = resty_sha256:new()
  sha256:update(str)
  local digest = sha256:final()

  return resty_str.to_hex(digest)
end

local function intersect(a, b)
  local set_b = {}
  for _, v in ipairs(b or {}) do
    set_b[v] = true
  end

  local result = {}
  for _, v in ipairs(a or {}) do
    if set_b[v] then
      table.insert(result, v)
    end
  end

  return result
end

function M.new(config)
  local _config = config or {}
  local instance = {
    config = {
      prefix = _config.prefix or "akey",
      auth_header = (_config.auth_header or 'x-api-key'):lower(),
      get_user_permissions = _config.get_user_permissions,
    },
    store = _config.store,
  }
  return setmetatable(instance, { __index = M })
end

-- `user_id` is the owning users.id (see store_api_key.lua's user_id FK,
-- and auth_jwt.lua's comment about keeping identity numeric throughout).
function M:authenticate(user_id, permissions, label, expires_in_days)
  -- 16 random bytes -> 32 hex characters
  local kid = resty_str.to_hex(random.bytes(16, true))

  -- 32 random bytes -> 64 hex characters
  local secret = resty_str.to_hex(random.bytes(32, true))

  local api_key = string.format("%s_%s.%s", self.config.prefix, kid, secret)

  local hash_secret = hash_str(secret)

  local current = self.config.get_user_permissions
    and self.config.get_user_permissions(user_id)
    or {}
  local requested = type(permissions) == "table" and permissions or current
  local granted = intersect(requested, current)

  -- Same "!%Y-%m-%d %H:%M:%S" UTC string format lib.routes'
  -- resolve_relative_date uses for this same TIMESTAMP column type - sorts
  -- correctly lexicographically, so get_context_from_request's expiry
  -- check below can compare it as a plain string rather than needing a
  -- real date parse.
  local expires_at = expires_in_days
    and os.date("!%Y-%m-%d %H:%M:%S", os.time() + expires_in_days * 86400)
    or nil

  self.store:create({
    user_id = user_id,
    kid = kid,
    label = label,
    revoked = false,
    hash_secret = hash_secret,
    permissions = cjson_safe.encode(granted),
    expires_at = expires_at,
  })

  return api_key
end

function M:get_context_from_request(request)
  local auth = request.req
    and request.req.headers
    and request.req.headers[self.config.auth_header]

  if not auth then
    return nil, string.format("Missing %s header", self.config.auth_header)
  end

  local prefix, kid, secret = auth:match("^(%w+)_(%w+)%.(.+)$")

  if prefix ~= self.config.prefix or not kid or not secret then
    return nil, "Invalid Authorization header format"
  end

  local record = self.store:find({ kid = kid })

  if not record then
    return nil, "Invalid API key"
  end

  if record.revoked then
    return nil, "Key is revoked"
  end

  -- record.expires_at comes back from pgmoon as a plain "YYYY-MM-DD
  -- HH:MM:SS" string (same TIMESTAMP-column convention lib.routes'
  -- resolve_relative_date relies on), NOT a number - comparing it against
  -- os.time() here would be a string-vs-number `<`, a hard Lua error, not
  -- a wrong-but-silent result. Compare as strings instead - this format
  -- sorts correctly lexicographically.
  if record.expires_at and record.expires_at < os.date("!%Y-%m-%d %H:%M:%S") then
    return nil, "Key is expired"
  end
  local secret_hash = hash_str(secret)

  if not secure_compare.equals(record.hash_secret, secret_hash) then
    return nil, "Invalid API key"
  end

  local stored_permissions = record.permissions
    and cjson_safe.decode(record.permissions)
    or {}
  local current_permissions = self.config.get_user_permissions
    and self.config.get_user_permissions(record.user_id)
    or {}

  return {
    user = record.user_id,
    auth_type = "api_key",
    permissions = intersect(stored_permissions, current_permissions),
  }
end

function M:list(user_id, options)
  local result, err = self.store:find_all_by_user_id(user_id, options)

  if not result then
    return nil, err or "Failed to list API keys"
  end

  local items = {}
  for _, record in ipairs(result.items) do
    table.insert(items, {
      id = record.id,
      kid = record.kid,
      label = record.label,
      permissions = record.permissions and cjson_safe.decode(record.permissions) or nil,
      revoked = record.revoked,
      revoked_reason = record.revoked_reason,
      expires_at = record.expires_at,
      created_at = record.created_at,
      updated_at = record.updated_at,
    })
  end

  return { items = items, total_items = result.total_items }
end

function M:remove(user_id, kid)
  local akey_context = { user_id = user_id, kid = kid }
  local record = self.store:find(akey_context)

  if not record then
    return nil, "API key was not found"
  end

  local ok, err = self.store:delete(akey_context)

  if not ok then
    return nil, err or "Failed to delete API key"
  end

  return true, "API key deleted"
end

function M:revoke(user_id, kid)
  local akey_context = { user_id = user_id, kid = kid }
  local record = self.store:find(akey_context)

  if not record then
    return nil, "API key was not found"
  end

  if record.revoked then
    return nil, "API key already revoked"
  end

  local ok, err = self.store:update(akey_context, { revoked = true })

  if not ok then
    return nil, err or "Failed to revoke API key"
  end

  return true, "API key revoked"
end

function M:update_label(user_id, kid, label)
  local akey_context = { user_id = user_id, kid = kid }
  local record = self.store:find(akey_context)

  if not record then
    return nil, "API key was not found"
  end

  local ok, err = self.store:update(akey_context, { label = label })

  if not ok then
    return nil, err or "Failed to update API key"
  end

  return true, "API key updated"
end

return M
