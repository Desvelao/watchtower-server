local db = require("lapis.db")
local route_helpers = require("lib.routes")
local password_hash = require("plugins.security.services.password_hash")
local cjson = require("cjson")
local zip_writer = require("lib.zip_writer")
local zip_reader = require("lib.zip_reader")

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
  local fields_query_params = {
    "id",
    "username",
    "role_id",
    "enabled",
    route_helpers.created_after_param(),
    route_helpers.created_before_param(),
  }
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

-- Filesystem-safe entry name for a user inside a multi-user export zip -
-- same 3-line helper as plugins/rules/services/rules.lua's own slugify,
-- duplicated rather than extracted for two call sites.
local function slugify(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    slug = "user"
  end
  return slug
end

-- A user exports as {username, role, enabled} - `role` by *name*, not
-- role_id (so the export is portable to another environment where that id
-- may not resolve to the same role), and deliberately no password field at
-- all: password_hash is scrypt-derived and can never round-trip (see
-- sanitize() above, which already strips it from every ordinary response
-- too). `ids`, if given, is an array of user ids to export; nil/empty
-- exports every user. Returns (content, content_type, filename) on
-- success, or (nil, nil, nil, error_message) when nothing matches. A
-- single matching user stays one .json file; 2+ are packed into a .zip
-- (one .json per user) via lib/zip_writer - see
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
    return nil, nil, nil, "No users to export"
  end

  local function to_export(row)
    return {
      username = row.username,
      role = self._roles:get_name(row.role_id),
      enabled = row.enabled,
    }
  end

  if #items == 1 then
    return cjson.encode(to_export(items[1])), "application/json; charset=utf-8", "users-export.json"
  end

  local files = {}
  for _, item in ipairs(items) do
    table.insert(files, {
      name = slugify(item.username) .. "-" .. item.id .. ".json",
      content = cjson.encode(to_export(item)),
    })
  end
  return zip_writer.build(files), "application/zip", "users-export.zip"
end

local ZIP_MAGIC = "PK\3\4" -- zip local-file-header signature

-- Parses (but does not save) an uploaded user file or zip of user files -
-- see plugins/rules/services/rules.lua's M:preflight_import for the
-- identical shape/precedent (zip-magic-byte sniff, one candidate per
-- entry). A user's `role` (exported by name) is resolved to a local
-- role_id here; an unresolvable role surfaces as a per-candidate error,
-- exactly like a bad rule `if` expression does, never a hard failure of
-- the whole batch. Returns an array of either `{ file, error }` (failed to
-- parse/resolve) or `{ file, username, role, role_id, enabled,
-- conflict: {id, username}|nil }` (parsed ok, with an existing
-- same-username user flagged for the caller to resolve). Nothing is
-- written to the DB - see M:commit_import for that.
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
      local role = payload.role and payload.role ~= "" and self._roles:find_by_name(payload.role)
      if not role then
        table.insert(candidates, {
          file = entry.name,
          error = "Role '" .. tostring(payload.role) .. "' not found",
        })
      else
        local row, derive_err = self:_derive({
          username = payload.username,
          role_id = role.id,
          enabled = payload.enabled,
        }, true)
        if not row then
          table.insert(candidates, { file = entry.name, error = derive_err })
        else
          local candidate = {
            file = entry.name,
            username = row.username,
            role = role.name,
            role_id = role.id,
            enabled = row.enabled,
          }
          local existing = self._model:find({ username = row.username })
          if existing then
            candidate.conflict = { id = existing.id, username = existing.username }
          end
          table.insert(candidates, candidate)
        end
      end
    end
  end

  return candidates
end

-- `items` is the frontend's resolved decisions from a preflight_import
-- result: `{ username, role_id, enabled, action = "create" | "update",
-- existing_id?, password? }[]`. Reuses M:create/M:update exactly as the
-- single-user form does - no validation logic is duplicated here. An
-- update never touches the password even if one was somehow sent; a
-- create requires one, mirroring M:create's own "password is required"
-- error. Any `action` other than exactly "create" or "update" (with a
-- truthy `existing_id`) - including the documented "skip" option, nil, or a
-- typo - is rejected as a no-op rather than falling through to create.
-- Returns a parallel array of `{ ok, error? }`, one per item, never
-- aborting the batch over one bad item (mirrors
-- plugins/rules/services/rules.lua's own M:commit_import).
function M:commit_import(items)
  local results = {}
  for _, item in ipairs(items) do
    local ok, row, err = pcall(function()
      if item.action == "update" and item.existing_id then
        return self:update(item.existing_id, {
          username = item.username,
          role_id = item.role_id,
          enabled = item.enabled,
        })
      elseif item.action == "create" then
        if type(item.password) ~= "string" or item.password == "" then
          return nil, "password is required"
        end
        return self:create({
          username = item.username,
          role_id = item.role_id,
          enabled = item.enabled,
          password = item.password,
        })
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
