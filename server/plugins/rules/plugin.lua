-- Rules: the condition language (`if:`) that decides which fired alert(s)
-- an ingested observation produces. The flat rule-document format and
-- boolean expression grammar themselves now live in the standalone
-- `rule_engine` LuaRocks package
-- (shared/rule_engine/{source,expr}.lua - see shared/rule_engine/README.md),
-- reused here (and by plugins/notification_channels/) rather than
-- reimplemented.
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")
local json_params = require("lapis.application").json_params
local analyzer_module = require("analyzer")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/rules"

-- The match context for POST .../test and .../test-expression: built from the
-- request's own observation-like fields by the same rule_matching.build_context
-- the analyzers use. With an observable_id, `changed`/`changed_within` are
-- evaluated against that observable's stored history as of now (nothing to
-- exclude - the sample observation isn't a stored row).
local function build_test_context(params)
  local has_observable = params.observable_id and params.observable_id ~= ""
  return require("watchtower_worker_core.rule_matching").build_context({
    source = params.source,
    payload = params.payload,
    observable_id = params.observable_id,
    worker = params.worker,
    observable_type = params.observable_type,
    timestamp = has_observable and require("lapis.db").format_date() or nil,
  }, function(observable_id, timestamp, seconds, exclude_id)
    return analyzer_module.fetch_baseline(tonumber(observable_id), timestamp, seconds, exclude_id)
  end)
end

local Plugin = {
  name = "rules",
  dependencies = { "security" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  local rule_engine_module = require("plugins.rules.services.rule_engine")
  local rule_engine = rule_engine_module.new(models.Rules)
  local rule_manager = require("plugins.rules.services.rules").new(models.Rules, {
    on_change = function()
      rule_engine:invalidate()
    end,
  })

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.RULES_READ),
      with_error_handling("Failed to list rules", "Failed to list rules")
    )(function(self)
      return { status = 200, json = rule_manager:search(self) }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.RULES_READ))(function(self)
      local item = rule_manager:find(self.params.id)
      if not item then
        return { status = 404, json = { message = "Rule not found", id = self.params.id } }
      end
      return { status = 200, json = { item = item } }
    end)
  )

  app:post(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.RULES_CREATE),
      with_json_body({
        { "source", types.valid_text },
      }),
      with_error_handling("Failed to create rule", "Failed to create rule")
    )(function(self)
      local item, err = rule_manager:create(self.params)
      if not item then
        return { status = 400, json = { message = "Invalid rule", error = err } }
      end
      return { status = 201, json = { message = "Rule created", item = item } }
    end)
  )

  app:put(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.RULES_UPDATE),
      with_json_body({
        { "source", types.valid_text },
      }),
      with_error_handling("Failed to update rule", "Failed to update rule")
    )(function(self)
      local item, err = rule_manager:update(self.params.id, self.params)
      if not item then
        return { status = 400, json = { message = "Invalid rule", error = err } }
      end
      return { status = 200, json = { message = "Rule updated", item = item } }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.RULES_DELETE),
      with_error_handling("Failed to delete rule", "Failed to delete rule")
    )(function(self)
      rule_manager:delete(self.params.id)
      return { status = 200, json = { message = "Rule deleted" } }
    end)
  )

  -- Downloads matching rules (all, or `?ids=1,2,3`) as a single .yaml file
  -- (exactly one match) or a .zip of one .yaml per rule (2+ matches) - see
  -- services/rules.lua's M:export. The zip is hand-rolled
  -- (lib/zip_writer.lua) rather than adding a new Luarocks dependency for
  -- it.
  app:get(
    base_path .. "/export",
    compose(
      require_auth,
      rbac:with(perms.RULES_READ),
      with_error_handling("Failed to export rules", "Failed to export rules")
    )(function(self)
      local ids = nil
      if self.params.ids and self.params.ids ~= "" then
        ids = {}
        for id_str in self.params.ids:gmatch("[^,]+") do
          table.insert(ids, tonumber(id_str))
        end
      end

      local content, content_type, filename, no_match_err = rule_manager:export(ids)

      if not content then
        return { status = 404, json = { message = no_match_err or "No rules to export" } }
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

  -- Parses+validates an uploaded rule file or zip of rule files without
  -- saving anything - see services/rules.lua's M:preflight_import. `file`
  -- is populated by Lapis' own multipart parsing (same convention as
  -- plugins/entities/items_routes.lua's import route), so no manual
  -- multipart-body reading is needed here.
  app:post(
    base_path .. "/import/preflight",
    compose(
      require_auth,
      rbac:with(perms.RULES_CREATE),
      with_error_handling("Failed to preflight rule import", "Failed to process upload")
    )(function(self)
      local file = self.params.file
      if not file then
        return { status = 400, json = { message = "File is missing." } }
      end

      local candidates, derive_err = rule_manager:preflight_import(file.filename, file.content)
      if not candidates then
        return { status = 400, json = { message = derive_err } }
      end

      return { status = 200, json = { items = candidates } }
    end)
  )

  -- Commits a client-resolved decision array from a prior preflight:
  -- `{ items: [{ source, action: "create"|"update", existing_id? }] }`.
  -- Gated on both RULES_CREATE and RULES_UPDATE since a single batch can
  -- do either. Plain JSON body (json_params, not with_json_body) since
  -- `items` is a variable-shape array, not a fixed field schema - see
  -- services/rules.lua's M:commit_import for the per-item, never-abort
  -- handling.
  app:post(
    base_path .. "/import",
    compose(
      require_auth,
      rbac:with(perms.RULES_CREATE),
      rbac:with(perms.RULES_UPDATE),
      with_error_handling("Failed to commit rule import", "Failed to import rules")
    )(json_params(function(self)
      local items = self.params.items
      if type(items) ~= "table" then
        return { status = 400, json = { message = "items must be an array" } }
      end

      local results = rule_manager:commit_import(items)

      return { status = 200, json = { results = results } }
    end))
  )

  -- Evaluates a sample observation-like payload against the current rules
  -- without persisting anything: no observation/alert row is created.
  -- Gated on RULES_READ (not OBSERVATIONS_CREATE) since nothing is written.
  app:post(
    base_path .. "/test",
    compose(
      require_auth,
      rbac:with(perms.RULES_READ),
      with_json_body({
        { "payload", types.empty + types.valid_text },
        { "source", types.empty + types.valid_text },
        { "observable_id", types.empty + types.valid_text + types.number },
        { "worker", types.empty + types.valid_text },
        { "observable_type", types.empty + types.valid_text },
      }),
      with_error_handling("Failed to test rules", "Failed to test rules")
    )(function(self)
      local context = build_test_context(self.params)

      local matches = rule_engine:match(context)

      return { status = 200, json = { matches = matches } }
    end)
  )

  -- Tests a single, ad-hoc `if:` expression against a sample
  -- observation-like payload, without saving a rule - lets an author
  -- preview a draft condition before committing it via POST/PUT /api/rules.
  app:post(
    base_path .. "/test-expression",
    compose(
      require_auth,
      rbac:with(perms.RULES_READ),
      with_json_body({
        { "if", types.valid_text },
        { "payload", types.empty + types.valid_text },
        { "source", types.empty + types.valid_text },
        { "observable_id", types.empty + types.valid_text + types.number },
        { "worker", types.empty + types.valid_text },
        { "observable_type", types.empty + types.valid_text },
      }),
      with_error_handling("Failed to test expression", "Failed to test expression")
    )(function(self)
      local context = build_test_context(self.params)

      local matched, err = rule_engine_module.test_expression(self.params["if"], context)

      if err then
        return { status = 400, json = { message = "Invalid expression", error = err } }
      end

      return { status = 200, json = { matched = matched } }
    end)
  )

  return {
    rule_manager = rule_manager,
    rule_engine = rule_engine,
  }
end

return Plugin
