local db = require("lapis.db")
local route_helpers = require("lib.routes")

local M = {}

function M.new(role_model, config)
  local _config = config or {}
  local instance = {
    _model = role_model,
    -- Set of every permission string the fixed catalog actually allows
    -- (permissions.lua's values) - a role can only ever be assigned a
    -- subset of these, never an invented string with no matching
    -- rbac:with(...) enforcement point anywhere in the app.
    _valid_permissions = _config.valid_permissions or {},
    on_change = _config.on_change,
  }
  return setmetatable(instance, { __index = M })
end

-- Called after every successful create/update/delete so the cached
-- role -> permissions lookup below (used by rbac.lua on every request)
-- gets rebuilt on next access, same pattern as the rules plugin's
-- rule_engine.invalidate() wired to rules.lua's on_change.
function M:_notify_change()
  if self.on_change then
    self.on_change()
  end
  self._cache = nil
end

function M:invalidate()
  self._cache = nil
end

function M:_load()
  local rows = self._model:select("order by name asc")
  local by_id = {}
  for _, row in ipairs(rows) do
    by_id[row.id] = { name = row.name, permissions = row.permissions or {} }
  end
  return by_id
end

function M:get_permissions(role_id)
  if not role_id then
    return {}
  end
  if not self._cache then
    self._cache = self:_load()
  end
  local entry = self._cache[role_id]
  return entry and entry.permissions or {}
end

function M:get_name(role_id)
  if not role_id then
    return nil
  end
  if not self._cache then
    self._cache = self:_load()
  end
  local entry = self._cache[role_id]
  return entry and entry.name or nil
end

-- Parses+validates create/update params. Returns (row, nil) or (nil, err).
function M:_derive(params)
  local name = params.name
  if type(name) ~= "string" or name == "" then
    return nil, "name is required"
  end

  local permissions = params.permissions
  if permissions == nil then
    permissions = {}
  elseif type(permissions) ~= "table" then
    return nil, "permissions must be an array"
  end

  for _, perm in ipairs(permissions) do
    if not self._valid_permissions[perm] then
      return nil, "Unknown permission: " .. tostring(perm)
    end
  end

  -- Postgres can't infer an empty ARRAY[]'s element type even in a typed
  -- INSERT target list ("cannot determine type of empty array") - db.raw
  -- with an explicit cast sidesteps db.array({})'s untyped ARRAY[].
  local permissions_value = #permissions > 0 and db.array(permissions)
    or db.raw("ARRAY[]::varchar[]")

  return {
    name = name,
    permissions = permissions_value,
  },
    nil
end

function M:list(request)
  local fields_query_params = {
    "name",
    {
      key = "permission",
      map_clause = function(p)
        return string.format("%s = ANY(permissions)", db.escape_literal(p.value))
      end,
    },
  }
  local fields_search_params = {
    {
      key = "name",
      map_clause = function(p)
        return route_helpers.escaped_like_clause("name", p.value)
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

  return { items = items, total_items = total_items }
end

function M:find(id)
  return self._model:find({ id = id })
end

function M:create(params)
  local row, err = self:_derive(params)
  if not row then
    return nil, err
  end

  local ok, item = pcall(function()
    return self._model:create(row)
  end)

  if not ok then
    if tostring(item):find("duplicate key", 1, true) then
      error({ status = 400, message = "A role named '" .. row.name .. "' already exists" })
    end
    error(item)
  end

  self:_notify_change()
  return item, nil
end

function M:update(id, params)
  local item = self._model:find({ id = id })
  if not item then
    return nil, "Role not found"
  end

  local row, err = self:_derive(params)
  if not row then
    return nil, err
  end
  row.updated_at = db.format_date()

  local ok, ok_update = pcall(function()
    return item:update(row)
  end)

  if not ok then
    if tostring(ok_update):find("duplicate key", 1, true) then
      error({ status = 400, message = "A role named '" .. row.name .. "' already exists" })
    end
    error(ok_update)
  end

  if not ok_update then
    return nil, "Update failed"
  end

  self:_notify_change()
  return self._model:find({ id = id }), nil
end

function M:delete(id)
  local item = self._model:find({ id = id })
  if not item then
    error({ status = 404, message = "Role not found" })
  end

  local ok, result = pcall(function()
    return item:delete()
  end)

  if not ok then
    if tostring(result):find("violates foreign key", 1, true) then
      error({ status = 400, message = "Role is still assigned to one or more users" })
    end
    error(result)
  end

  self:_notify_change()
  return result
end

return M
