local db = require("lapis.db")
local route_helpers = require("lib.routes")
local password_hash = require("plugins.security.services.password_hash")

local M = {}

function M.new(user_model, roles_service)
  local instance = {
    _model = user_model,
    _roles = roles_service,
  }
  return setmetatable(instance, { __index = M })
end

-- Strips password_hash before a row is ever handed to a route handler for
-- a JSON response - the raw row (see find_raw/authenticate below) is only
-- ever used internally (auth.lua's get_user callback, get_user_permissions).
local function sanitize(row)
  if not row then
    return nil
  end
  return {
    id = row.id,
    username = row.username,
    role_id = row.role_id,
    enabled = row.enabled,
    created_at = row.created_at,
    updated_at = row.updated_at,
  }
end

-- Raw row (including password_hash) - used only by auth.lua's get_user
-- callback and the security plugin's get_user_permissions, never returned
-- to a route. Looked up by id (not username) - see auth_jwt.lua's comment
-- on keeping identity numeric throughout the auth chain.
function M:find_raw(id)
  return self._model:find({ id = id })
end

-- Same shape as find_raw, kept as a distinct name so auth.lua's wiring
-- (`function(user) return users:find(user) end`) reads naturally as "find
-- this authenticated request's user" - both resolve to the same raw row.
M.find = M.find_raw

function M:authenticate(username, password)
  local user = self._model:find({ username = username })
  if not user then
    return nil
  end
  if user.enabled == false then
    return nil
  end
  if not password_hash.verify(password, user.password_hash) then
    return nil
  end
  return user
end

function M:_derive(params, is_create)
  local username = params.username
  if is_create and (type(username) ~= "string" or username == "") then
    return nil, "username is required"
  end

  local role_id = params.role_id
  if role_id ~= nil then
    role_id = tonumber(role_id)
    if not role_id or not self._roles:find(role_id) then
      return nil, "role_id must reference an existing role"
    end
  elseif is_create then
    return nil, "role_id is required"
  end

  local enabled = params.enabled
  if enabled == nil then
    enabled = is_create and true or nil
  end

  local row = {}
  if username ~= nil then
    row.username = username
  end
  if role_id ~= nil then
    row.role_id = role_id
  end
  if enabled ~= nil then
    row.enabled = enabled
  end

  return row, nil
end

function M:list(request)
  local fields_query_params = { "id", "username", "role_id", "enabled" }
  local fields_search_params = {
    {
      key = "username",
      map_clause = function(p)
        return route_helpers.escaped_like_clause("username", p.value)
      end,
    },
  }

  local params = {}
  for _, v in ipairs(fields_query_params) do
    table.insert(params, v)
  end
  table.insert(params, {
    key = "search",
    map_clause = route_helpers.create_search_map_clause(fields_search_params),
  })

  local where_params = params
  local query = route_helpers.get_db_query_params_from_request_params(request, where_params)
  local where_clause = route_helpers.get_db_where_clause_from_request_params(request, where_params)

  local items = self._model:select(query)
  local total_items = self._model:count(where_clause)

  local sanitized = {}
  for _, item in ipairs(items) do
    table.insert(sanitized, sanitize(item))
  end

  return { items = sanitized, total_items = total_items }
end

function M:create(params)
  local row, err = self:_derive(params, true)
  if not row then
    return nil, err
  end

  local password = params.password
  if type(password) ~= "string" or password == "" then
    return nil, "password is required"
  end
  row.password_hash = password_hash.hash(password)

  local ok, item = pcall(function()
    return self._model:create(row)
  end)

  if not ok then
    if tostring(item):find("duplicate key", 1, true) then
      error({ status = 400, message = "A user named '" .. row.username .. "' already exists" })
    end
    error(item)
  end

  return sanitize(item), nil
end

function M:update(id, params)
  local item = self._model:find({ id = id })
  if not item then
    return nil, "User not found"
  end

  local row, err = self:_derive(params, false)
  if not row then
    return nil, err
  end
  row.updated_at = db.format_date()

  local ok, ok_update = pcall(function()
    return item:update(row)
  end)

  if not ok then
    if tostring(ok_update):find("duplicate key", 1, true) then
      error({ status = 400, message = "A user named '" .. tostring(row.username) .. "' already exists" })
    end
    error(ok_update)
  end

  if not ok_update then
    return nil, "Update failed"
  end

  return sanitize(self._model:find({ id = id })), nil
end

-- The single method that ever writes password_hash outside M:create -
-- backs a dedicated PUT /api/users/:id/password route, deliberately kept
-- separate from M:update so a general profile edit can never accidentally
-- carry a password change along with it.
function M:reset_password(id, new_password)
  local item = self._model:find({ id = id })
  if not item then
    return nil, "User not found"
  end
  if type(new_password) ~= "string" or new_password == "" then
    return nil, "password is required"
  end

  local ok_update = item:update({
    password_hash = password_hash.hash(new_password),
    updated_at = db.format_date(),
  })
  if not ok_update then
    return nil, "Failed to reset password"
  end

  return true, nil
end

function M:delete(id)
  local item = self._model:find({ id = id })
  if not item then
    error({ status = 404, message = "User not found" })
  end
  return item:delete()
end

return M
