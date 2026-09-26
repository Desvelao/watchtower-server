-- Generic observer-configuration registry, generalizing the removed
-- single-observable-type plugins/scraper_remote_config_lua predecessor
-- to ANY observable_type and (in the future) any observer_type. See
-- config/dataset/init.sql's "Observer configs"/"Observer config test
-- requests" sections and lib/observer_type_catalog.lua's header comment
-- for the full design rationale.
local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local models = require("models")
local types = require("lapis.validate.types")
local route_helpers = require("lib.routes")
local capture_bad_request_params_validate = route_helpers.capture_bad_request_params_validate
local get_optional_query_parameters = route_helpers.get_optional_query_parameters
local created_after_param = route_helpers.created_after_param
local created_before_param = route_helpers.created_before_param
local compose = route_helpers.compose
local with_error_handling = route_helpers.with_error_handling
local tableshape = require("tableshape").types
local tobool_from_key = require("lib.utils").tobool_from_key
local jsonb_query = require("lib.jsonb_query")
local observer_field_schema = require("lib.observer_field_schema")
local observer_type_catalog = require("lib.observer_type_catalog")
local property_schema = require("lib.property_schema")
local cjson = require("cjson")

local base_path = "/api/observer_configs"

local validate_string_non_empty = tableshape.custom(function(val)
  if type(val) == "string" and #val > 0 then
    return true
  end
  return nil, "Should be a non-empty string"
end)
local validate_number = tableshape.custom(function(val)
  if type(val) == "number" then
    return true
  end
  return nil, "Should be a number"
end)
-- fields/mechanism_config are now arbitrary/admin-authored per observable
-- type (see derive_observer_config_fields), so only these top-level
-- request shape checks remain here - the rest is validated generically
-- against the target observable type's schemas.

local Plugin = {
  name = "observer_configs",
  dependencies = { "security", "entities" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local observable_type_manager = deps.entities.observable_type_manager
  local require_auth = auth:with({ require = true })

  local search_manager = require("lib.resource_manager").new(models.ObserverConfigs, {
    fields_query_params = {
      "id",
      "name",
      "observable_type_id",
      "enabled",
      created_after_param(),
      created_before_param(),
    },
    fields_search_params = { "name" },
  })

  -- Resolves observable_type_id -> its observer_config_schema/
  -- observer_mechanism_schema, and validates `fields` (data.fields) and
  -- `mechanism_config` (data.mechanism_config, a nested object - not flat
  -- top-level params, since its field set is now arbitrary/admin-authored
  -- and could collide with this request's own other top-level keys)
  -- against them, using the catalog's one implemented observer type (see
  -- lib/observer_type_catalog.lua's M.default() - observer_type isn't a
  -- per-observable-type choice, there's nothing else to choose today).
  -- Returns (true, {observable_type, observer_type, fields,
  -- mechanism_config}) with `fields`/`mechanism_config` as plain (not yet
  -- JSON-encoded) Lua tables, or (false, err). Shared by create/update/import
  -- (which JSON-encode the result into a DB row) and the ad-hoc test route
  -- (which embeds it directly into an observer_config_test_requests.config
  -- JSON blob).
  local function derive_observer_config_fields(data)
    local observable_type = observable_type_manager:find(data.observable_type_id)
    if not observable_type then
      return false, "observable_type_id: no such observable type"
    end

    local catalog_entry, observer_type = observer_type_catalog.default()

    local required = observer_field_schema.required_field_names(observable_type.observer_config_schema)
    local ok_fields, fields_or_err = observer_field_schema.validate_fields(data.fields, required, catalog_entry.validate_field_def)
    if not ok_fields then
      return false, "fields: " .. fields_or_err
    end

    -- Generic, exactly like `fields` above - validated against the
    -- observable type's own admin-authored observer_mechanism_schema
    -- rather than a hardcoded per-observer-type validator (see
    -- lib/observer_type_catalog.lua's header comment).
    local ok_mech, mech_or_err = property_schema.validate_values(observable_type.observer_mechanism_schema, data.mechanism_config)
    if not ok_mech then
      return false, "mechanism_config: " .. mech_or_err
    end

    return true, {
      observable_type = observable_type,
      observer_type = observer_type,
      fields = fields_or_err,
      mechanism_config = mech_or_err,
    }
  end

  -- Validates+builds an observer_configs row (ready for
  -- models.ObserverConfigs:create/:update) from a create/update/import
  -- request body, or (nil, err) - mirrors
  -- plugins/entities/observable_types_routes.lua's derive_row.
  local function derive_observer_config_row(data)
    local ok, derived_or_err = derive_observer_config_fields(data)
    if not ok then
      return nil, derived_or_err
    end

    return {
      name = data.name,
      observable_type_id = derived_or_err.observable_type.id,
      fields = jsonb_query.encode(derived_or_err.fields),
      mechanism_config = jsonb_query.encode(derived_or_err.mechanism_config),
      enabled = data.enabled ~= false,
    }
  end

  local function decode_created(item)
    -- models.ObserverConfigs decorates :select/:find/:find_all to decode
    -- fields/mechanism_config automatically, but not :create/:update's own
    -- return value - decoded here instead.
    if item then
      item.fields = jsonb_query.decode(item.fields)
      item.mechanism_config = jsonb_query.decode(item.mechanism_config)
    end
    return item
  end

  app:get(base_path, compose(require_auth, rbac:with(perms.OBSERVER_CONFIGS_READ))(get_optional_query_parameters({
    { "from", tableshape.number, tonumber },
    { "size", tableshape.number, tonumber },
    { "enabled", tableshape.boolean, tobool_from_key },
    { "observable_type_id", tableshape.number, tonumber },
    { "name", tableshape.string, nil },
    { "search", tableshape.string, nil },
    { "sort", tableshape.string, nil },
    { "id", tableshape.number, tonumber },
  })(with_error_handling("Failed to list observer configs", "Unable to get the observer configs list.")(function(self)
    local result = search_manager:search(self)
    return { status = 200, json = result }
  end))))

  app:post(base_path, compose(require_auth, rbac:with(perms.OBSERVER_CONFIGS_CREATE))(json_params(function(self)
    local row, err = derive_observer_config_row(self.params)
    if not row then
      return { status = 400, json = { message = err } }
    end

    local ok, result = pcall(function()
      return search_manager:create(row)
    end)
    if not ok then
      return { status = 500, json = { message = tostring(result) } }
    end

    return { status = 201, json = { success = true, message = "Observer config added successfully.", item = decode_created(result) } }
  end)))

  app:put(base_path .. "/:id", compose(
    require_auth,
    rbac:with(perms.OBSERVER_CONFIGS_UPDATE),
    with_error_handling("Failed to update observer config", "Unable to update observer config.")
  )(capture_bad_request_params_validate({
    { "id", types.db_id },
  })(function(self)
    local row, err = derive_observer_config_row(self.params)
    if not row then
      return { status = 400, json = { message = err } }
    end

    -- search_manager:update raises {status=404,...} for a missing id
    -- (see lib/resource_manager.lua) - caught by with_error_handling above,
    -- same convention as plugins/scheduler/plugin.lua's own PUT route.
    local _, updated = search_manager:update(self.params.id, row)

    return { json = { success = true, message = "Observer config updated successfully.", item = decode_created(updated) } }
  end)))

  app:delete(base_path .. "/:id", compose(
    require_auth,
    rbac:with(perms.OBSERVER_CONFIGS_DELETE),
    with_error_handling("Failed to delete observer config", "Unable to remove observer config.")
  )(capture_bad_request_params_validate({
    { "id", types.db_id },
  })(function(self)
    -- search_manager:delete raises {status=404,...} for a missing id -
    -- caught by with_error_handling above.
    search_manager:delete(self.params.id)
    return { json = { success = true, message = "Observer config removed successfully." } }
  end)))

  app:get(base_path .. "/export", compose(require_auth, rbac:with(perms.OBSERVER_CONFIGS_READ))(function(self)
    local items = models.ObserverConfigs:select("order by name asc")
    local filename = "observer_configs_export_" .. os.date("%Y-%m-%d") .. ".json"
    return {
      status = 200,
      headers = {
        ["Content-Type"] = "application/json",
        ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
      },
      layout = false,
      json = { description = "Observer configs", items = items or {} },
    }
  end))

  app:post(base_path .. "/import", compose(
    require_auth,
    rbac:with(perms.OBSERVER_CONFIGS_CREATE),
    with_error_handling("Failed to import observer configs", "Unable to import observer configs.")
  )(function(self)
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
      -- row comes straight from the uploaded file's JSON, so it may be
      -- anything (a malformed item - JSON null, a bare string/number/
      -- boolean - not just a well-formed-but-invalid object); pcall guards
      -- derive_observer_config_row itself (which indexes fields on it as a
      -- table) rather than trusting it to always return (nil, err) for bad
      -- input, mirroring source_document_manager.lua's M:commit_import
      -- skip-and-report convention.
      local ok_derive, derived = pcall(derive_observer_config_row, row)
      if not ok_derive or not derived then
        failed = failed + 1
      else
        local ok_create, new_item = pcall(function()
          return search_manager:create(derived)
        end)
        if ok_create then
          table.insert(created, decode_created(new_item))
        else
          failed = failed + 1
        end
      end
    end

    return { json = { ok = true, content = { items = created, failed = failed } } }
  end))

  -- Test routes (.../test, .../:id/test, .../test/_all) - a plain blocking
  -- observe call here would risk stalling this nginx worker's whole event
  -- loop, so these
  -- only ever record the request (an observer_config_test_requests row) and
  -- return its id immediately; a worker claims it as a type='observer_test'
  -- job (see .../test_requests/pending below and the worker-side
  -- observer_config_test_poller) and runs the actual observe off the request
  -- cycle. The frontend polls GET /api/jobs/for/observer_test/:id.
  -- Validates `data.properties` against `observable_type`'s own `properties`
  -- schema (the same call plugins/entities/observables_routes.lua uses to
  -- validate a real Observable's properties) and resolves which of them
  -- holds the URL to observe via property_schema.find_url_property - there's
  -- no server-side "url_property" concept beyond this convention (see
  -- worker_plugins/watchtower_observer_web_scraper/observers/web_scraper.lua's own
  -- worker-local url_property, which defaults to, and in practice always
  -- is, this same property). Returns (true, {properties, test_url}) or
  -- (false, err).
  local function derive_test_target(observable_type, properties)
    local ok_props, properties_or_err = property_schema.validate_values(observable_type.properties, properties)
    if not ok_props then
      return false, "properties: " .. properties_or_err
    end
    local url_property = property_schema.find_url_property(observable_type.properties)
    if not url_property then
      return false, "observable_type_id: observable type has no url-typed property to test against"
    end
    return true, { properties = properties_or_err, test_url = properties_or_err[url_property.name] }
  end

  app:post(base_path .. "/test", compose(require_auth, rbac:with(perms.OBSERVER_CONFIGS_CREATE))(capture_bad_request_params_validate({
    { "observable_type_id", validate_number },
    { "name", validate_string_non_empty },
  })(function(self)
    local ok, derived_or_err = derive_observer_config_fields(self.params)
    if not ok then
      return { status = 400, json = { message = derived_or_err } }
    end

    local ok_target, target_or_err = derive_test_target(derived_or_err.observable_type, self.params.properties)
    if not ok_target then
      return { status = 400, json = { message = target_or_err } }
    end

    local request = models.ObserverConfigTestRequests:create({
      config = jsonb_query.encode({
        mode = "adhoc",
        observable_type_id = derived_or_err.observable_type.id,
        observer_type = derived_or_err.observer_type,
        name = self.params.name,
        fields = derived_or_err.fields,
        mechanism_config = derived_or_err.mechanism_config,
        properties = target_or_err.properties,
      }),
      test_url = target_or_err.test_url,
    })

    return { status = 202, json = { id = request.id } }
  end)))

  app:post(base_path .. "/:id/test", compose(require_auth, rbac:with(perms.OBSERVER_CONFIGS_CREATE))(capture_bad_request_params_validate({
    { "id", types.db_id },
  })(function(self)
    local item = models.ObserverConfigs:find({ id = self.params.id })
    if not item then
      return { status = 404, json = { message = "Observer config not found", id = self.params.id } }
    end
    local observable_type = observable_type_manager:find(item.observable_type_id)
    if not observable_type then
      return { status = 400, json = { message = "observable_type_id: no such observable type" } }
    end

    local ok_target, target_or_err = derive_test_target(observable_type, self.params.properties)
    if not ok_target then
      return { status = 400, json = { message = target_or_err } }
    end

    local request = models.ObserverConfigTestRequests:create({
      config = jsonb_query.encode({ mode = "saved", observer_config_id = self.params.id, properties = target_or_err.properties }),
      test_url = target_or_err.test_url,
    })

    return { status = 202, json = { id = request.id } }
  end)))

  app:post(base_path .. "/test/_all", compose(require_auth, rbac:with(perms.OBSERVER_CONFIGS_CREATE))(capture_bad_request_params_validate({
    { "observable_type_id", validate_number },
  })(function(self)
    local observable_type = observable_type_manager:find(self.params.observable_type_id)
    if not observable_type then
      return { status = 400, json = { message = "observable_type_id: no such observable type" } }
    end
    local _, observer_type = observer_type_catalog.default()

    local ok_target, target_or_err = derive_test_target(observable_type, self.params.properties)
    if not ok_target then
      return { status = 400, json = { message = target_or_err } }
    end

    local request = models.ObserverConfigTestRequests:create({
      config = jsonb_query.encode({
        mode = "all",
        observable_type_id = observable_type.id,
        observer_type = observer_type,
        properties = target_or_err.properties,
      }),
      test_url = target_or_err.test_url,
    })

    return { status = 202, json = { id = request.id } }
  end)))

  -- Worker-facing poll endpoint, scoped to THIS plugin's own tables only -
  -- the oldest observer_config_test_requests row with no
  -- type='observer_test' job yet. Unlike plugins/scheduler's
  -- claim_next_batch/plugins/notification_channels' delivery_queue:claim_batch,
  -- there's no pre-existing 'pending' jobs row to atomically flip to
  -- 'triggering' here (a test request has no jobs row at all until claimed) -
  -- so the claim itself has to both pick the candidate AND create that row,
  -- in one transaction: SELECT ... FOR UPDATE OF octr SKIP LOCKED locks the
  -- candidate row (a second concurrent caller's own SELECT ... FOR UPDATE
  -- SKIP LOCKED then skips it rather than blocking, and re-checks the same
  -- `LEFT JOIN jobs ... WHERE j.id IS NULL` condition against whatever's
  -- left), then the INSERT durably records the claim (worker_id + status=
  -- 'triggering') before the transaction commits and the row becomes
  -- visible to any other request - unlike a lock alone, which would only
  -- protect the claim for the lifetime of this one transaction, not for the
  -- (possibly much longer) time until the worker's own follow-up
  -- PUT /api/jobs/observer_test/:id/triggering report. That follow-up report
  -- still happens exactly as before (see worker_plugins/
  -- watchtower_observer_web_scraper/observer_config_test_poller.lua) - it
  -- just now updates the row this claim already inserted (same worker_id,
  -- already status='triggering') rather than racing to be the first to
  -- create it, so a same-status re-report is properly reflected via
  -- services/jobs.lua:report's own `retries` bookkeeping rather than two
  -- workers both succeeding at creating their own independent 'triggering'
  -- row for the same ref_id (jobs_active_unique_idx is keyed on worker_id,
  -- so it can't catch that - only this row-level lock can). Mirrored by
  -- server/workers/observe_pending_worker.lua's embedded_provider:
  -- next_observer_test, the direct-DB counterpart to this HTTP route.
  app:get(base_path .. "/test_requests/pending", compose(
    require_auth,
    rbac:with(perms.WORKERS_WRITE),
    with_error_handling("Failed to fetch pending observer config test", "Unable to fetch pending observer config test.")
  )(capture_bad_request_params_validate({
    { "worker_id", validate_string_non_empty },
  })(function(self)
    local claimed = route_helpers.with_transaction(function()
      local rows = db.query([[
        SELECT octr.id, octr.config, octr.test_url
        FROM observer_config_test_requests octr
        LEFT JOIN jobs j ON j.type = 'observer_test' AND j.ref_id = octr.id
        WHERE j.id IS NULL
        ORDER BY octr.created_at ASC
        LIMIT 1
        FOR UPDATE OF octr SKIP LOCKED
      ]])

      local row = rows[1]
      if not row then
        return nil
      end

      db.query([[
        INSERT INTO jobs (worker_id, type, ref_id, status, taken_at)
        VALUES (?, 'observer_test', ?, 'triggering', NOW())
      ]], self.params.worker_id, row.id)

      return row
    end)

    if not claimed then
      return { status = 200, json = { item = nil } }
    end

    return {
      status = 200,
      json = {
        item = {
          id = claimed.id,
          config = jsonb_query.decode(claimed.config),
          test_url = claimed.test_url,
        },
      },
    }
  end)))

  -- Worker-facing remote-sites-equivalent fetch, for a
  -- sites_source="remote"+remote_source="observer_configs" observer
  -- (standalone worker only - the embedded worker reads
  -- models.ObserverConfigs directly, see server/workers/observe_pending_worker.lua).
  -- Pre-reshaped via the catalog's `to_site`, so the worker needs no
  -- reshaping of its own - scoped to one observable_type_id since this
  -- table spans many.
  app:get(base_path .. "/site", compose(require_auth, rbac:with(perms.OBSERVER_CONFIGS_READ))(function(self)
    local observable_type_id = tonumber(self.params.observable_type_id)
    if not observable_type_id then
      return { status = 400, json = { message = "observable_type_id is required" } }
    end

    local observable_type = observable_type_manager:find(observable_type_id)
    if not observable_type then
      return { status = 400, json = { message = "observable_type_id: no such observable type" } }
    end

    local catalog_entry = observer_type_catalog.default()

    local rows = models.ObserverConfigs:select(
      "where observable_type_id = ? and enabled = true order by name asc",
      observable_type_id
    )

    local items = {}
    for i, row in ipairs(rows) do
      items[i] = catalog_entry.to_site(row)
    end

    return { status = 200, json = { items = items } }
  end))

  return {}
end

return Plugin
