local M = {}

-- `config.roles` is a "roles provider" object with a `get_permissions(role_id)`
-- method (services/roles.lua - a cached DB-backed lookup), not a static
-- role-name -> permissions table. This is what lets editing a role, or
-- reassigning/disabling a user, take effect immediately on the very next
-- request instead of waiting for the JWT to expire/re-login.
function M.new(config, get_auth_payload)
  local _config = config or {}
  if not _config.permissions or type(_config.permissions) ~= "table" then
    error(
      "Permissions table is required. Please provide a permissions table mapping roles to permissions."
    )
  end
  if not _config.roles or type(_config.roles) ~= "table" then
    error(
      "Roles provider is required. Please provide an object with a get_permissions(role_id) method."
    )
  end
  if not get_auth_payload or type(get_auth_payload) ~= "function" then
    error(
      "Auth payload getter is required. Please provide the auth payload getter module."
    )
  end
  local instance = {
    config = {
      permissions = _config.permissions,
      roles = _config.roles,
    },
    perms = {},
    get_auth_payload = get_auth_payload,
  }

  for key, value in pairs(instance.config.permissions) do
    instance.perms[key] = value
  end

  return setmetatable(instance, { __index = M })
end

-- `auth` is the whole `that.auth` object built by services/auth.lua's
-- `with()` (`{is_authenticated, context, user}`), not just the token's raw
-- payload - API-key auth already resolves/clamps its permissions upstream
-- (auth_api_key.lua) so `auth.context.permissions` is checked directly,
-- but JWT auth's `context.role` is a display-only claim never trusted
-- here: instead `auth.user.role_id` (the live DB row auth.lua already
-- fetched this request) is looked up in the roles provider fresh, every
-- time.
function M:get_permissions(auth)
  if not auth then
    return {}
  end

  if auth.context and auth.context.permissions then
    return auth.context.permissions
  elseif auth.user and auth.user.role_id then
    return self.config.roles:get_permissions(auth.user.role_id)
  end

  return {}
end

function M:has_permission(auth, permission)
  for _, perm in ipairs(self:get_permissions(auth)) do
    if perm == permission then
      return true
    end
  end
  return false
end

function M:with(permission)
  return function(fn)
    return function(that)
      local auth = self.get_auth_payload(that)
      if not self:has_permission(auth, permission) then
        return {
          status = 403,
          json = {
            error = "Forbidden",
            message = "You do not have permission for this action",
            required_permission = permission,
          },
        }
      end
      that.rbac = {
        role_id = auth.user and auth.user.role_id,
        permissions = auth.context and auth.context.permissions,
        has_permissions = true,
      }
      return fn(that)
    end
  end
end

return M
