-- Rules: the condition language (`if:`) that decides which fired alert(s)
-- an ingested event produces. Ported from pibuzz's rules/rule_engine
-- services - see services/rule_source.lua for the flat rule-document
-- format and shared/rule_expr.lua for the boolean expression grammar.
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/rules"

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

  -- Evaluates a sample event-like payload against the current rules
  -- without persisting anything: no event/alert row is created. Gated on
  -- RULES_READ (not EVENTS_CREATE) since nothing is written.
  app:post(
    base_path .. "/test",
    compose(
      require_auth,
      rbac:with(perms.RULES_READ),
      with_json_body({
        { "payload", types.empty + types.valid_text },
        { "source", types.empty + types.valid_text },
        { "tags", types.empty + types.array_of(types.valid_text) },
        { "item_id", types.empty + types.valid_text + types.number },
        { "price", types.empty + types.number },
        { "discount", types.empty + types.valid_text },
        { "available", types.empty + types.boolean },
        { "url", types.empty + types.valid_text },
      }),
      with_error_handling("Failed to test rules", "Failed to test rules")
    )(function(self)
      local matches = rule_engine:match({
        source = self.params.source,
        tags = self.params.tags,
        payload = self.params.payload,
        item_id = self.params.item_id,
        price = self.params.price,
        discount = self.params.discount,
        available = self.params.available,
        url = self.params.url,
      })

      return { status = 200, json = { matches = matches } }
    end)
  )

  -- Tests a single, ad-hoc `if:` expression against a sample event-like
  -- payload, without saving a rule - lets an author preview a draft
  -- condition before committing it via POST/PUT /api/rules.
  app:post(
    base_path .. "/test-expression",
    compose(
      require_auth,
      rbac:with(perms.RULES_READ),
      with_json_body({
        { "if", types.valid_text },
        { "payload", types.empty + types.valid_text },
        { "source", types.empty + types.valid_text },
        { "tags", types.empty + types.array_of(types.valid_text) },
        { "item_id", types.empty + types.valid_text + types.number },
        { "price", types.empty + types.number },
        { "discount", types.empty + types.valid_text },
        { "available", types.empty + types.boolean },
        { "url", types.empty + types.valid_text },
      }),
      with_error_handling("Failed to test expression", "Failed to test expression")
    )(function(self)
      local matched, err = rule_engine_module.test_expression(self.params["if"], {
        source = self.params.source,
        tags = self.params.tags,
        payload = self.params.payload,
        item_id = self.params.item_id,
        price = self.params.price,
        discount = self.params.discount,
        available = self.params.available,
        url = self.params.url,
      })

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
