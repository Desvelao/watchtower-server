-- Authentication & authorization: users, roles, API keys. Every other
-- plugin that needs auth declares `dependencies = {'security'}` and
-- receives this plugin's setup() return value as `deps.security` - see
-- server/lib/plugins-service.lua.
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")
local json_params = require("lapis.application").json_params

local compose = route_helpers.compose
local with_error_handling = route_helpers.with_error_handling
local error_response = route_helpers.error_response
-- Same JSON-body validation every plugin already uses (see lib/routes.lua),
-- just under a shorter local alias.
local with_json_body = route_helpers.capture_bad_request_params_validate

local PERMS = require("plugins.security.permissions")

local base_path = "/api"

local Plugin = {
  name = "security",
}

function Plugin.setup(app)
  local jwt_secret = os.getenv("JWT_SECRET")
  if not jwt_secret or jwt_secret == "" then
    error("JWT_SECRET env var is required")
  end

  local valid_permissions = {}
  for _, value in pairs(PERMS) do
    valid_permissions[value] = true
  end

  local roles = require("plugins.security.services.roles").new(
    models.Roles,
    { valid_permissions = valid_permissions }
  )
  local users = require("plugins.security.services.users").new(models.Users, roles)

  -- Also respects a disabled account: a still-valid API key issued before
  -- the account was disabled gets clamped to zero permissions on its very
  -- next use, same immediate-effect property the JWT path gets from
  -- rbac.lua reading the live user row directly.
  local function get_user_permissions(user_id)
    local user = users:find(user_id)
    return (user and user.enabled and roles:get_permissions(user.role_id)) or {}
  end

  local auth = require("plugins.security.services.auth").new({
    jwt = { jwt_secret = jwt_secret },
    api_key = {
      store = require("plugins.security.services.store_api_key").new(models.ApiKeys),
      get_user_permissions = get_user_permissions,
    },
  }, function(user_id)
    return users:find(user_id)
  end)

  local rbac = require("plugins.security.services.rbac").new({
    permissions = PERMS,
    roles = roles,
  }, function(request)
    return request.auth or {}
  end)

  local rate_limit = require("plugins.security.services.rate_limit").new()

  app:post(
    base_path .. "/auth/login",
    compose(
      rate_limit:with(),
      with_json_body({
        { "username", types.valid_text },
        { "password", types.valid_text },
      })
    )(function(self)
      local username, password = self.params.username, self.params.password
      local user = users:authenticate(username, password)

      if not user then
        return { status = 401, json = { error = "Invalid credentials" } }
      end

      -- Display-only claim from here on - never trusted for enforcement,
      -- see rbac.lua (permissions are resolved from the live user row's
      -- role_id on every request instead).
      local role_name = roles:get_name(user.role_id)
      local token = auth:authenticate("jwt", user.id, role_name)

      return {
        status = 200,
        json = { message = "Login successful", token = token, role = role_name },
      }
    end)
  )

  app:get(
    base_path .. "/auth/me",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      with_error_handling("Failed to get current user", "Failed to get current user")
    )(function(self)
      return {
        status = 200,
        json = {
          username = self.auth.user.username,
          role = roles:get_name(self.auth.user.role_id),
          permissions = rbac:get_permissions(self.auth),
        },
      }
    end)
  )

  app:post(
    base_path .. "/auth/api_key",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.API_KEY_MANAGE),
      with_json_body({
        { "label", types.valid_text },
        { "permissions", types.empty + types.array_of(types.valid_text) },
        { "expires_in_days", types.empty + types.number },
      })
    )(function(self)
      local token, err = auth:authenticate(
        "api_key",
        self.auth.user.id,
        self.params.permissions,
        self.params.label,
        self.params.expires_in_days
      )

      if not token then
        return { status = 400, json = { message = "API key creation failed", error = err } }
      end

      return { status = 200, json = { message = "API key created", api_key = token } }
    end)
  )

  app:post(
    base_path .. "/auth/api_key/:kid/revoke",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.API_KEY_MANAGE)
    )(function(self)
      local kid = self.params.kid
      local ok, err = auth:get_provider("api_key"):revoke(self.auth.user.id, kid)

      if not ok then
        return { status = 400, json = { message = "API key revokation failed", error = err } }
      end

      return { status = 200, json = { message = "API key revoked", id = kid } }
    end)
  )

  app:put(
    base_path .. "/auth/api_key/:kid",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.API_KEY_MANAGE),
      with_json_body({
        { "label", types.valid_text },
      })
    )(function(self)
      local kid = self.params.kid
      local ok, err =
        auth:get_provider("api_key"):update_label(self.auth.user.id, kid, self.params.label)

      if not ok then
        return { status = 400, json = { message = "API key update failed", error = err } }
      end

      return {
        status = 200,
        json = { message = "API key updated", id = kid, label = self.params.label },
      }
    end)
  )

  app:get(
    base_path .. "/auth/api_key",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.API_KEY_MANAGE)
    )(function(self)
      local from = self.params.from and tonumber(self.params.from) or nil
      local size = self.params.size and tonumber(self.params.size) or nil

      local result, err = auth:get_provider("api_key"):list(self.auth.user.id, {
        from = from,
        size = size,
        search = self.params.search,
        status = self.params.status,
        permissions = self.params.permissions,
        created_after = self.params.created_after,
        created_before = self.params.created_before,
      })

      if not result then
        return error_response(err, "Failed to list API keys")
      end

      return { status = 200, json = result }
    end)
  )

  app:delete(
    base_path .. "/auth/api_key/:kid",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.API_KEY_MANAGE)
    )(function(self)
      local kid = self.params.kid
      local ok, err = auth:get_provider("api_key"):remove(self.auth.user.id, kid)

      if not ok then
        return { status = 400, json = { message = "API key deletion failed", error = err } }
      end

      return { status = 200, json = { message = "API key deleted", id = kid } }
    end)
  )

  app:get(
    base_path .. "/users",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_READ),
      with_error_handling("Failed to list users", "Failed to list users")
    )(function(self)
      return { status = 200, json = users:list(self) }
    end)
  )

  app:post(
    base_path .. "/users",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_CREATE),
      with_json_body({
        { "username", types.valid_text },
        { "password", types.valid_text },
        { "role_id", types.valid_text + types.number },
      }),
      with_error_handling("Failed to create user", "Failed to create user")
    )(function(self)
      local item, err = users:create(self.params)
      if not item then
        return { status = 400, json = { message = "Invalid user", error = err } }
      end

      return { status = 201, json = { message = "User created", item = item } }
    end)
  )

  app:put(
    base_path .. "/users/:id",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_UPDATE),
      with_json_body({
        { "username", types.empty + types.valid_text },
        { "role_id", types.empty + types.valid_text + types.number },
        { "enabled", types.empty + types.boolean },
      }),
      with_error_handling("Failed to update user", "Failed to update user")
    )(function(self)
      local item, err = users:update(self.params.id, self.params)
      if not item then
        return { status = 400, json = { message = "Invalid user", error = err } }
      end

      return { status = 200, json = { message = "User updated", item = item } }
    end)
  )

  app:put(
    base_path .. "/users/:id/password",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_UPDATE),
      with_json_body({
        { "password", types.valid_text },
      }),
      with_error_handling("Failed to reset password", "Failed to reset password")
    )(function(self)
      local ok, err = users:reset_password(self.params.id, self.params.password)
      if not ok then
        return { status = 400, json = { message = "Invalid request", error = err } }
      end

      return { status = 200, json = { message = "Password updated" } }
    end)
  )

  app:delete(
    base_path .. "/users/:id",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_DELETE),
      with_error_handling("Failed to delete user", "Failed to delete user")
    )(function(self)
      users:delete(self.params.id)
      return { status = 200, json = { message = "User deleted" } }
    end)
  )

  -- Downloads matching users (all, or `?ids=1,2,3`) as a single .json file
  -- (exactly one match) or a .zip of one .json per user (2+ matches) - see
  -- services/users.lua's M:export. Mirrors plugins/rules/plugin.lua's own
  -- GET /api/rules/export route verbatim.
  app:get(
    base_path .. "/users/export",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_READ),
      with_error_handling("Failed to export users", "Failed to export users")
    )(function(self)
      local ids = nil
      if self.params.ids and self.params.ids ~= "" then
        ids = {}
        for id_str in self.params.ids:gmatch("[^,]+") do
          table.insert(ids, tonumber(id_str))
        end
      end

      local content, content_type, filename, no_match_err = users:export(ids)

      if not content then
        return { status = 404, json = { message = no_match_err or "No users to export" } }
      end

      return {
        status = 200,
        content_type = content_type,
        headers = { ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"' },
        layout = false,
        content,
      }
    end)
  )

  -- Parses+validates an uploaded user file or zip of user files without
  -- saving anything - see services/users.lua's M:preflight_import. `file`
  -- is populated by Lapis' own multipart parsing, same as
  -- plugins/rules/plugin.lua's own import/preflight route.
  app:post(
    base_path .. "/users/import/preflight",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_CREATE),
      with_error_handling("Failed to preflight user import", "Failed to process upload")
    )(function(self)
      local file = self.params.file
      if not file then
        return { status = 400, json = { message = "File is missing." } }
      end

      local candidates, derive_err = users:preflight_import(file.filename, file.content)
      if not candidates then
        return { status = 400, json = { message = derive_err } }
      end

      return { status = 200, json = { items = candidates } }
    end)
  )

  -- Commits a client-resolved decision array from a prior preflight:
  -- `{ items: [{ username, role_id, enabled, action: "create"|"update",
  -- existing_id?, password? }] }`. Gated on both USERS_CREATE and
  -- USERS_UPDATE since a single batch can do either - see
  -- services/users.lua's M:commit_import for the per-item, never-abort
  -- handling.
  app:post(
    base_path .. "/users/import",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.USERS_CREATE),
      rbac:with(PERMS.USERS_UPDATE),
      with_error_handling("Failed to commit user import", "Failed to import users")
    )(json_params(function(self)
      local items = self.params.items
      if type(items) ~= "table" then
        return { status = 400, json = { message = "items must be an array" } }
      end

      local results = users:commit_import(items)

      return { status = 200, json = { results = results } }
    end))
  )

  app:get(
    base_path .. "/roles",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.ROLES_READ),
      with_error_handling("Failed to list roles", "Failed to list roles")
    )(function(self)
      return { status = 200, json = roles:list(self) }
    end)
  )

  app:post(
    base_path .. "/roles",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.ROLES_CREATE),
      with_json_body({
        { "name", types.valid_text },
        { "permissions", types.empty + types.array_of(types.valid_text) },
      }),
      with_error_handling("Failed to create role", "Failed to create role")
    )(function(self)
      local item, err = roles:create(self.params)
      if not item then
        return { status = 400, json = { message = "Invalid role", error = err } }
      end

      return { status = 201, json = { message = "Role created", item = item } }
    end)
  )

  app:put(
    base_path .. "/roles/:id",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.ROLES_UPDATE),
      with_json_body({
        { "name", types.valid_text },
        { "permissions", types.empty + types.array_of(types.valid_text) },
      }),
      with_error_handling("Failed to update role", "Failed to update role")
    )(function(self)
      local item, err = roles:update(self.params.id, self.params)
      if not item then
        return { status = 400, json = { message = "Invalid role", error = err } }
      end

      return { status = 200, json = { message = "Role updated", item = item } }
    end)
  )

  app:delete(
    base_path .. "/roles/:id",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.ROLES_DELETE),
      with_error_handling("Failed to delete role", "Failed to delete role")
    )(function(self)
      roles:delete(self.params.id)
      return { status = 200, json = { message = "Role deleted" } }
    end)
  )

  -- Downloads matching roles (all, or `?ids=1,2,3`) as a single .json file
  -- (exactly one match) or a .zip of one .json per role (2+ matches) - see
  -- services/roles.lua's M:export. Mirrors plugins/rules/plugin.lua's own
  -- GET /api/rules/export route verbatim.
  app:get(
    base_path .. "/roles/export",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.ROLES_READ),
      with_error_handling("Failed to export roles", "Failed to export roles")
    )(function(self)
      local ids = nil
      if self.params.ids and self.params.ids ~= "" then
        ids = {}
        for id_str in self.params.ids:gmatch("[^,]+") do
          table.insert(ids, tonumber(id_str))
        end
      end

      local content, content_type, filename, no_match_err = roles:export(ids)

      if not content then
        return { status = 404, json = { message = no_match_err or "No roles to export" } }
      end

      return {
        status = 200,
        content_type = content_type,
        headers = { ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"' },
        layout = false,
        content,
      }
    end)
  )

  -- Parses+validates an uploaded role file or zip of role files without
  -- saving anything - see services/roles.lua's M:preflight_import. `file`
  -- is populated by Lapis' own multipart parsing, same as
  -- plugins/rules/plugin.lua's own import/preflight route.
  app:post(
    base_path .. "/roles/import/preflight",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.ROLES_CREATE),
      with_error_handling("Failed to preflight role import", "Failed to process upload")
    )(function(self)
      local file = self.params.file
      if not file then
        return { status = 400, json = { message = "File is missing." } }
      end

      local candidates, derive_err = roles:preflight_import(file.filename, file.content)
      if not candidates then
        return { status = 400, json = { message = derive_err } }
      end

      return { status = 200, json = { items = candidates } }
    end)
  )

  -- Commits a client-resolved decision array from a prior preflight:
  -- `{ items: [{ name, permissions, action: "create"|"update",
  -- existing_id? }] }`. Gated on both ROLES_CREATE and ROLES_UPDATE since a
  -- single batch can do either - see services/roles.lua's M:commit_import
  -- for the per-item, never-abort handling.
  app:post(
    base_path .. "/roles/import",
    compose(
      rate_limit:with(),
      auth:with({ require = true }),
      rbac:with(PERMS.ROLES_CREATE),
      rbac:with(PERMS.ROLES_UPDATE),
      with_error_handling("Failed to commit role import", "Failed to import roles")
    )(json_params(function(self)
      local items = self.params.items
      if type(items) ~= "table" then
        return { status = 400, json = { message = "items must be an array" } }
      end

      local results = roles:commit_import(items)

      return { status = 200, json = { results = results } }
    end))
  )

  return {
    auth = auth,
    rbac = rbac,
    rate_limit = rate_limit,
    users = users,
    roles = roles,
    perms = PERMS,
  }
end

return Plugin
