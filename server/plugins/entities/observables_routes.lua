-- Observables CRUD (/api/observables, unchanged base path shape & permission
-- catalog structure from the old server/plugins/items/plugin.lua before the
-- Items->Observables rename). Generalized to be observable-type-driven: an
-- observable's shape-specific fields live in `properties` (jsonb), validated
-- against its observable_type's `properties` schema via lib/property_schema.lua
-- instead of a fixed url column.
local db = require("lapis.db")
local models = require("models")
local route_helpers = require("lib.routes")
local property_schema = require("lib.property_schema")
local jsonb_query = require("lib.jsonb_query")
local types = require("lapis.validate.types")
local tableshape = require("tableshape").types
local tobool_from_key = require("lib.utils").tobool_from_key
local cjson = require("cjson")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local get_optional_query_parameters = route_helpers.get_optional_query_parameters
local get_db_query_params_from_request_params = route_helpers.get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = route_helpers.get_db_where_clause_from_request_params
local create_search_map_clause = route_helpers.create_search_map_clause
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/observables"

-- Kept from the old items plugin (moved to `local`, fixing the previous
-- global-leak: they used to be declared as bare globals inside setup()).
-- Only invoked when the observable's observable type declares a url-typed property.
local function slugify_url_path(url)
  local path = url:match("https?://[^/]+(/.*)") or "/"
  path = path:gsub("%?.*$", ""):gsub("#.*$", "")
  local last_segment = path:match(".*/([^/]+)$") or path
  local slug = last_segment:lower()
  slug = slug:gsub("[^a-z0-9]+", "-")
  slug = slug:gsub("^-+", ""):gsub("-+$", "")
  if slug == "" then
    slug = "untitled"
  end
  return slug
end

local function domain_plus_slug(url)
  local domain = url:match("https?://([^/]+)") or "unknown-domain"
  local slug = slugify_url_path(url)
  return domain .. "-" .. slug
end

local function decode_observable(observable)
  if not observable then
    return observable
  end
  observable.properties = jsonb_query.decode(observable.properties)
  return observable
end

return function(app, deps, observable_type_manager)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  local function where_params_for(observable_type)
    local where_params = {
      "enabled",
      "name",
      "id",
      "observable_type_id",
      route_helpers.created_after_param(),
      route_helpers.created_before_param(),
      {
        key = "updated_after",
        map_clause = function(p)
          return "updated_at >= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
        end,
      },
      {
        key = "updated_before",
        map_clause = function(p)
          return "updated_at <= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
        end,
      },
    }
    local search_columns = { "name" }

    if observable_type then
      for _, p in ipairs(jsonb_query.where_params_for_schema("properties", observable_type.properties)) do
        table.insert(where_params, p)
      end
      for _, c in ipairs(jsonb_query.searchable_columns("properties", observable_type.properties)) do
        table.insert(search_columns, c)
      end
    end

    table.insert(where_params, { key = "search", map_clause = create_search_map_clause(search_columns) })
    return where_params
  end

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.OBSERVABLES_READ),
      get_optional_query_parameters({
        { "from", tableshape.number, tonumber },
        { "size", tableshape.number, tonumber },
        { "enabled", tableshape.boolean, tobool_from_key },
        { "name", tableshape.string, nil },
        { "search", tableshape.string, nil },
        { "sort", tableshape.string, nil },
        { "id", tableshape.number, tonumber },
        { "observable_type_id", tableshape.number, tonumber },
      }),
      with_error_handling("Failed to list observables", "Unable to get the observables list.")
    )(function(self)
      local observable_type = self.params.observable_type_id and observable_type_manager:find(self.params.observable_type_id)
      local where_params = where_params_for(observable_type)

      local db_query = get_db_query_params_from_request_params(self, where_params)
      local where_clause = get_db_where_clause_from_request_params(self, where_params)

      local observables = models.Observables:select(db_query)
      local total_items = models.Observables:count(where_clause)
      for _, observable in ipairs(observables) do
        decode_observable(observable)
      end

      return { json = { items = observables or {}, total_items = total_items } }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.OBSERVABLES_READ))(function(self)
      local observable = models.Observables:find({ id = self.params.id })
      if not observable then
        return { status = 404, json = { message = "Observable was not found", id = self.params.id } }
      end
      return { json = { observable = decode_observable(observable) } }
    end)
  )

  app:post(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.OBSERVABLES_CREATE),
      with_json_body({
        { "name", types.empty + types.valid_text },
        { "observable_type_id", types.db_id },
        { "enabled", tableshape.boolean },
      }),
      with_error_handling("Failed to create observable", "Unable to add observable.")
    )(function(self)
      local observable_type = observable_type_manager:find(self.params.observable_type_id)
      if not observable_type then
        return { status = 404, json = { message = "Observable type not found", id = self.params.observable_type_id } }
      end

      local ok, normalized_or_err = property_schema.validate_values(observable_type.properties, self.params.properties)
      if not ok then
        return { status = 400, json = { message = normalized_or_err } }
      end

      local name = self.params.name
      if not name or name == "" then
        local url_prop = property_schema.find_url_property(observable_type.properties)
        if url_prop and normalized_or_err[url_prop.name] then
          name = domain_plus_slug(normalized_or_err[url_prop.name])
        else
          return { status = 400, json = { message = "name is required for this observable type." } }
        end
      end

      local new_observable = models.Observables:create({
        name = name,
        observable_type_id = self.params.observable_type_id,
        enabled = self.params.enabled,
        properties = jsonb_query.encode(normalized_or_err),
      })

      return {
        status = 201,
        json = { success = true, message = "Observable added successfully.", observable = decode_observable(new_observable) },
      }
    end)
  )

  app:put(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.OBSERVABLES_UPDATE),
      with_json_body({
        { "id", types.db_id },
        { "name", types.valid_text },
        { "enabled", tableshape.boolean },
      }),
      with_error_handling("Failed to update observable", "Unable to update observable.")
    )(function(self)
      local observable = models.Observables:find({ id = self.params.id })
      if not observable then
        return { status = 404, json = { message = "Observable was not found", id = self.params.id } }
      end

      -- observable_type_id is immutable after creation - not accepted here even
      -- if present in the body.
      local observable_type = observable_type_manager:find(observable.observable_type_id)
      local ok, normalized_or_err = property_schema.validate_values(
        observable_type and observable_type.properties,
        self.params.properties
      )
      if not ok then
        return { status = 400, json = { message = normalized_or_err } }
      end

      local opr, err = observable:update({
        name = self.params.name,
        enabled = self.params.enabled,
        properties = jsonb_query.encode(normalized_or_err),
        updated_at = db.format_date(),
      })

      if not opr then
        return { status = 500, json = { message = err or "Unable to update observable." } }
      end

      return { json = { success = true, message = "Observable updated successfully." } }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.OBSERVABLES_DELETE))(function(self)
      local id = self.params.id
      if not id then
        return { status = 400, json = { error = "Missing observable id." } }
      end

      local opr, err = models.Observables:find({ id = id }):delete()
      if not opr then
        return { status = 500, json = { error = err or "Unable to remove observable." } }
      end

      return { json = { success = true, message = "Observable removed successfully." } }
    end)
  )

  app:get(
    base_path .. "/export",
    compose(require_auth, rbac:with(perms.OBSERVABLES_READ))(function(self)
      local ok, result = pcall(function()
        local observables = models.Observables:select()
        for _, observable in ipairs(observables) do
          decode_observable(observable)
        end
        return { observables = observables }
      end)

      if not ok then
        return { status = 500, json = { error = result or "Unable to get the list." } }
      end

      local date_str = os.date("%Y-%m-%d")
      local filename = "export_observables_" .. date_str .. ".json"
      return {
        status = 200,
        headers = {
          ["Content-Type"] = "application/json",
          ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
        },
        layout = false,
        json = { description = "Observables configuration", observables = result.observables or {} },
      }
    end)
  )

  app:post(
    base_path .. "/import",
    compose(require_auth, rbac:with(perms.OBSERVABLES_CREATE))(function(self)
      local file = self.params.file
      if not file then
        return { status = 400, json = { error = "File is missing." } }
      end

      local ok_decode, decoded = pcall(cjson.decode, file.content)
      if not ok_decode then
        return { status = 500, json = { ok = false, error = "File content could not be decoded" } }
      end

      local created, failed = {}, 0
      for _, row in ipairs(decoded.observables or {}) do
        local ok_values, normalized_or_err

        local observable_type = row.observable_type_id and observable_type_manager:find(row.observable_type_id)
        if not observable_type then
          ok_values, normalized_or_err = false, "Unknown or missing observable_type_id"
        else
          ok_values, normalized_or_err = property_schema.validate_values(observable_type.properties, row.properties)
        end

        if ok_values then
          local ok_create, new_observable = pcall(function()
            return models.Observables:create({
              name = row.name,
              observable_type_id = row.observable_type_id,
              enabled = row.enabled,
              properties = jsonb_query.encode(normalized_or_err),
            })
          end)
          if ok_create then
            table.insert(created, new_observable)
          else
            failed = failed + 1
          end
        else
          failed = failed + 1
        end
      end

      return { json = { ok = true, content = { observables = created, failed = failed } } }
    end)
  )
end
