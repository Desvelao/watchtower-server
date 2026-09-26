-- Observable type CRUD (/api/observable_types) plus the small cache wrapper
-- returned to observables_routes/observations_routes so they can look up a
-- type's schema without a DB round-trip per request. observable_types has a
-- fixed row shape (id/name/label/description/properties/observation_schema)
-- so, unlike observables/observations, this goes through lib/resource_manager.lua
-- directly.
local db = require("lapis.db")
local models = require("models")
local route_helpers = require("lib.routes")
local property_schema = require("lib.property_schema")
local jsonb_query = require("lib.jsonb_query")
local types = require("lapis.validate.types")
local cjson = require("cjson")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/observable_types"

local function decode_row(row)
  if not row then
    return row
  end
  row.properties = jsonb_query.decode(row.properties)
  row.observation_schema = jsonb_query.decode(row.observation_schema)
  row.observer_config_schema = jsonb_query.decode(row.observer_config_schema)
  row.observer_mechanism_schema = jsonb_query.decode(row.observer_mechanism_schema)
  return row
end

-- Cache + invalidate() over models.ObservableTypes, same idiom as
-- plugins/rules/services/rule_engine.lua and
-- plugins/security/services/roles.lua - avoids re-querying observable_types on
-- every observables/observations request just to read a type's schema.
local function new_observable_type_manager()
  local self = {}

  function self:invalidate()
    self._cache = nil
  end

  function self:_load()
    local rows = models.ObservableTypes:select("order by name asc")
    local by_id = {}
    for _, row in ipairs(rows) do
      by_id[row.id] = decode_row(row)
    end
    return by_id
  end

  function self:find(id)
    if not id then
      return nil
    end
    if not self._cache then
      self._cache = self:_load()
    end
    return self._cache[tonumber(id) or id]
  end

  function self:list()
    if not self._cache then
      self._cache = self:_load()
    end
    local all = {}
    for _, row in pairs(self._cache) do
      table.insert(all, row)
    end
    return all
  end

  return self
end

return function(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  local observable_type_manager = new_observable_type_manager()

  local search_manager = require("lib.resource_manager").new(models.ObservableTypes, {
    fields_query_params = {
      "id",
      "name",
      route_helpers.created_after_param(),
      route_helpers.created_before_param(),
    },
    fields_search_params = { "name", "label" },
  })

  -- Validates both schema arrays of a create/update body. Returns
  -- (row, nil) ready for models.ObservableTypes:create/:update, or (nil, err).
  -- Takes a plain params table (not `self`) so the import route below can
  -- reuse it per-row without going through a request context.
  local function derive_row(params)
    local ok_props, properties_or_err = property_schema.validate_schema(params.properties)
    if not ok_props then
      return nil, "properties: " .. properties_or_err
    end
    local ok_obs, observation_schema_or_err = property_schema.validate_schema(params.observation_schema)
    if not ok_obs then
      return nil, "observation_schema: " .. observation_schema_or_err
    end
    local ok_observer, observer_config_schema_or_err = property_schema.validate_schema(params.observer_config_schema)
    if not ok_observer then
      return nil, "observer_config_schema: " .. observer_config_schema_or_err
    end
    local ok_mechanism, observer_mechanism_schema_or_err = property_schema.validate_schema(params.observer_mechanism_schema)
    if not ok_mechanism then
      return nil, "observer_mechanism_schema: " .. observer_mechanism_schema_or_err
    end

    return {
      name = params.name,
      label = params.label,
      description = params.description,
      properties = jsonb_query.encode(properties_or_err),
      observation_schema = jsonb_query.encode(observation_schema_or_err),
      observer_config_schema = jsonb_query.encode(observer_config_schema_or_err),
      observer_mechanism_schema = jsonb_query.encode(observer_mechanism_schema_or_err),
    }
  end

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.OBSERVABLE_TYPES_READ),
      with_error_handling("Failed to list observable types", "Failed to get the observable types list.")
    )(function(self)
      local result = search_manager:search(self)
      for _, row in ipairs(result.items) do
        decode_row(row)
      end
      return { status = 200, json = result }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.OBSERVABLE_TYPES_READ))(function(self)
      local item = search_manager:find(self.params.id)
      if not item then
        return { status = 404, json = { message = "Observable type not found", id = self.params.id } }
      end
      return { json = { item = decode_row(item) } }
    end)
  )

  app:post(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.OBSERVABLE_TYPES_CREATE),
      with_json_body({
        { "name", types.valid_text },
        { "label", types.empty + types.valid_text },
        { "description", types.empty + types.valid_text },
      })
    )(function(self)
      local row, err = derive_row(self.params)
      if not row then
        return { status = 400, json = { message = err } }
      end

      local ok, result = pcall(function()
        return models.ObservableTypes:create(row)
      end)

      if not ok then
        if tostring(result):find("duplicate key", 1, true) then
          return { status = 409, json = { message = "An observable type named '" .. tostring(row.name) .. "' already exists" } }
        end
        return { status = 500, json = { message = "Unable to create observable type." } }
      end

      observable_type_manager:invalidate()
      return { status = 201, json = { item = decode_row(result) } }
    end)
  )

  app:put(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.OBSERVABLE_TYPES_UPDATE),
      with_json_body({
        { "id", types.db_id },
        { "name", types.valid_text },
        { "label", types.empty + types.valid_text },
        { "description", types.empty + types.valid_text },
      })
    )(function(self)
      -- Note: changing a type's schema does not retroactively re-validate
      -- existing observables/observations of that type - accepted tradeoff of
      -- validating properties/observation_schema in Lua rather than at the
      -- DB layer (see docs/dev/observable-types-storage.md).
      local row, err = derive_row(self.params)
      if not row then
        return { status = 400, json = { message = err } }
      end

      local item = models.ObservableTypes:find({ id = self.params.id })
      if not item then
        return { status = 404, json = { message = "Observable type not found", id = self.params.id } }
      end

      row.updated_at = db.format_date()
      local ok, result = pcall(function()
        return item:update(row)
      end)

      if not ok then
        if tostring(result):find("duplicate key", 1, true) then
          return { status = 409, json = { message = "An observable type named '" .. tostring(row.name) .. "' already exists" } }
        end
        return { status = 500, json = { message = "Unable to update observable type." } }
      end

      observable_type_manager:invalidate()
      return { json = { item = decode_row(models.ObservableTypes:find({ id = self.params.id })) } }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.OBSERVABLE_TYPES_DELETE))(function(self)
      local item = models.ObservableTypes:find({ id = self.params.id })
      if not item then
        return { status = 404, json = { message = "Observable type not found", id = self.params.id } }
      end

      local ok, result = pcall(function()
        return item:delete()
      end)

      if not ok then
        if tostring(result):find("violates foreign key", 1, true) then
          local count = models.Observables:count("observable_type_id = ?", self.params.id)
          return {
            status = 409,
            json = { message = string.format("Cannot delete: %d observable(s) use this observable type.", count) },
          }
        end
        return { status = 500, json = { message = "Unable to delete observable type." } }
      end

      observable_type_manager:invalidate()
      return { json = { message = "Observable type deleted" } }
    end)
  )

  app:get(
    base_path .. "/export",
    compose(require_auth, rbac:with(perms.OBSERVABLE_TYPES_READ))(function(self)
      local items = models.ObservableTypes:select("order by name asc")
      for _, item in ipairs(items) do
        decode_row(item)
      end

      local filename = "observable_types_export_" .. os.date("%Y-%m-%d") .. ".json"
      return {
        status = 200,
        headers = {
          ["Content-Type"] = "application/json",
          ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
        },
        layout = false,
        json = { description = "Observable types configuration", items = items },
      }
    end)
  )

  app:post(
    base_path .. "/import",
    compose(require_auth, rbac:with(perms.OBSERVABLE_TYPES_CREATE))(function(self)
      local file = self.params.file
      if not file then
        return { status = 400, json = { message = "File is missing." } }
      end

      local ok_decode, decoded = pcall(cjson.decode, file.content)
      if not ok_decode then
        return { status = 500, json = { ok = false, error = "File content could not be decoded" } }
      end

      local created, failed = {}, 0
      for _, row in ipairs(decoded.items or {}) do
        local derived, err = derive_row(row)
        if not derived then
          failed = failed + 1
        else
          local ok_create, new_item = pcall(function()
            return models.ObservableTypes:create(derived)
          end)
          if ok_create then
            table.insert(created, decode_row(new_item))
          else
            failed = failed + 1
          end
        end
      end

      if #created > 0 then
        observable_type_manager:invalidate()
      end

      return { json = { ok = true, content = { items = created, failed = failed } } }
    end)
  )

  return observable_type_manager
end
