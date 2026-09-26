local db = require("lapis.db")
local route_helpers = require("lib.routes")
local cjson = require("cjson")
local zip_writer = require("lib.zip_writer")
local zip_reader = require("lib.zip_reader")

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
-- `is_create` mirrors services/users.lua's own M:_derive: on create, an
-- omitted `permissions` defaults to {} (a brand-new role with no
-- permissions); on update, an omitted `permissions` is left untouched
-- entirely (not included in the returned row at all) rather than wiping the
-- role's existing permission set - the route's own validation
-- (types.empty + types.array_of(...)) allows omitting it on both
-- POST and PUT, so the service layer is what must draw this distinction.
function M:_derive(params, is_create)
  local name = params.name
  if type(name) ~= "string" or name == "" then
    return nil, "name is required"
  end

  local permissions = params.permissions
  if permissions == nil then
    if is_create then
      permissions = {}
    end
  elseif type(permissions) ~= "table" then
    return nil, "permissions must be an array"
  end

  local row = { name = name }

  if permissions ~= nil then
    for _, perm in ipairs(permissions) do
      if not self._valid_permissions[perm] then
        return nil, "Unknown permission: " .. tostring(perm)
      end
    end

    -- Postgres can't infer an empty ARRAY[]'s element type even in a typed
    -- INSERT target list ("cannot determine type of empty array") - db.raw
    -- with an explicit cast sidesteps db.array({})'s untyped ARRAY[].
    row.permissions = #permissions > 0 and db.array(permissions)
      or db.raw("ARRAY[]::varchar[]")
  end

  return row, nil
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

-- Resolves a role by its unique `name` rather than id - needed here (export
-- collision checks) and by services/users.lua (resolving a user's `role`
-- name, exported/imported in place of the DB-internal role_id) to reference
-- a role portably across environments/exports.
function M:find_by_name(name)
  return self._model:find({ name = name })
end

function M:create(params)
  local row, err = self:_derive(params, true)
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

-- Filesystem-safe entry name for a role inside a multi-role export zip -
-- same 3-line helper as plugins/rules/services/rules.lua's own slugify,
-- duplicated rather than extracted for two call sites.
local function slugify(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    slug = "role"
  end
  return slug
end

-- A role exports as plain {name, permissions} JSON - no password-style
-- secret to strip, unlike users. `ids`, if given, is an array of role ids
-- to export; nil/empty exports every role. Returns (content, content_type,
-- filename) on success, or (nil, nil, nil, error_message) when nothing
-- matches. A single matching role stays one .json file; 2+ are packed into
-- a .zip (one .json per role) via lib/zip_writer - see
-- plugins/rules/services/rules.lua's M:export for the identical shape.
function M:export(ids)
  local query = "order by id asc"
  if ids and #ids > 0 then
    local escaped = {}
    for _, id in ipairs(ids) do
      table.insert(escaped, db.escape_literal(tonumber(id)))
    end
    query = "where id in (" .. table.concat(escaped, ", ") .. ") order by id asc"
  end

  local items = self._model:select(query)

  if #items == 0 then
    return nil, nil, nil, "No roles to export"
  end

  local function to_export(row)
    return { name = row.name, permissions = row.permissions or {} }
  end

  if #items == 1 then
    return cjson.encode(to_export(items[1])), "application/json; charset=utf-8", "roles-export.json"
  end

  local files = {}
  for _, item in ipairs(items) do
    table.insert(files, {
      name = slugify(item.name) .. "-" .. item.id .. ".json",
      content = cjson.encode(to_export(item)),
    })
  end
  return zip_writer.build(files), "application/zip", "roles-export.zip"
end

local ZIP_MAGIC = "PK\3\4" -- zip local-file-header signature

-- Parses (but does not save) an uploaded role file or zip of role files -
-- see plugins/rules/services/rules.lua's M:preflight_import for the
-- identical shape/precedent (zip-magic-byte sniff, one candidate per
-- entry). Returns an array of either `{ file, error }` (failed to parse) or
-- `{ file, name, permissions, conflict: {id, name}|nil }` (parsed ok, with
-- an existing same-named role flagged for the caller to resolve). Nothing
-- is written to the DB - see M:commit_import for that.
function M:preflight_import(filename, bytes)
  local entries
  if bytes:sub(1, 4) == ZIP_MAGIC then
    local files, err = zip_reader.read(bytes)
    if not files then
      return nil, "Could not read zip: " .. err
    end
    entries = files
  else
    entries = { { name = filename, content = bytes } }
  end

  local candidates = {}
  for _, entry in ipairs(entries) do
    local ok, payload = pcall(cjson.decode, entry.content)
    if not ok or type(payload) ~= "table" then
      table.insert(candidates, { file = entry.name, error = "Invalid JSON: " .. tostring(payload) })
    else
      local row, derive_err = self:_derive(payload, true)
      if not row then
        table.insert(candidates, { file = entry.name, error = derive_err })
      else
        local candidate = { file = entry.name, name = payload.name, permissions = payload.permissions or {} }
        local existing = self:find_by_name(payload.name)
        if existing then
          candidate.conflict = { id = existing.id, name = existing.name }
        end
        table.insert(candidates, candidate)
      end
    end
  end

  return candidates
end

-- `items` is the frontend's resolved decisions from a preflight_import
-- result: `{ name, permissions, action = "create" | "update",
-- existing_id? }[]`. Reuses M:create/M:update exactly as the single-role
-- form does - no validation logic is duplicated here. Any `action` other
-- than exactly "create" or "update" (with a truthy `existing_id`) -
-- including the documented "skip" option, nil, or a typo - is rejected as
-- a no-op rather than falling through to create. Returns a parallel array
-- of `{ ok, error? }`, one per item, never aborting the batch over one bad
-- item (mirrors plugins/rules/services/rules.lua's own M:commit_import).
function M:commit_import(items)
  local results = {}
  for _, item in ipairs(items) do
    local ok, row, err = pcall(function()
      if item.action == "update" and item.existing_id then
        return self:update(item.existing_id, { name = item.name, permissions = item.permissions })
      elseif item.action == "create" then
        return self:create({ name = item.name, permissions = item.permissions })
      end
      return nil, "Unsupported action '" .. tostring(item.action) .. "' (expected 'create', or 'update' with existing_id)"
    end)

    if ok and row then
      table.insert(results, { ok = true })
    elseif ok then
      table.insert(results, { ok = false, error = err })
    else
      local error_message = type(row) == "table" and row.message or tostring(row)
      table.insert(results, { ok = false, error = error_message })
    end
  end
  return results
end

return M
