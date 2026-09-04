-- Events: the sole entry point for getting an alert into the system.
-- Creating an event resolves rule matches (plugins/rules) synchronously
-- and creates one linked `alerts` row per matched rule (via
-- plugins/alerting's alert_manager), or a single fallback row with a null
-- pattern/rule_id when nothing matches, as a side effect. Ported from
-- pibuzz's event_manager/on_create hook in application/main.lua.
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")
local db = require("lapis.db")
local cjson_safe = require("cjson.safe")
local Logger = require("core.logger")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local logger = Logger:new("ERROR", function(level, message)
  return string.format("[%s] %s", level, message)
end)

local base_path = "/api/events"

local Plugin = {
  name = "events",
  dependencies = { "security", "rules", "alerting" },
}

-- Derives the fields for the alert linked to `event` from a single rule
-- match (or nil for the no-match fallback alert). A matched rule's
-- severity/tags override the event's own values; nil falls back to them
-- (priority defaults to "low" since events carry no priority of their
-- own).
local function derive_alert_fields(event, match)
  return {
    event_id = event.id,
    priority = (match and match.severity) or "low",
    tags = (match and match.tags) or event.tags,
    pattern = match and match.action or nil,
    rule_id = match and match.id or nil,
  }
end

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })
  local rule_engine = deps.rules.rule_engine
  local alert_manager = deps.alerting.alert_manager

  -- Builds the rule-matching context for `event`: source/tags/payload as
  -- pibuzz's grammar always supported, plus price/discount/available/url
  -- lifted to flat top-level fields from the event's own JSON payload (an
  -- observation's ingest, see plugins/observations/plugin.lua) so a rule
  -- can write `price < 300` directly instead of `payload.price < 300` -
  -- the raw payload string is still passed through unchanged for any rule
  -- that prefers `payload.*` access to a field this doesn't lift.
  local function build_match_context(event)
    local payload_data = {}
    if type(event.payload) == "string" then
      payload_data = cjson_safe.decode(event.payload) or {}
    end

    return {
      source = event.source,
      tags = event.tags,
      payload = event.payload,
      item_id = event.item_id,
      price = payload_data.price,
      discount = payload_data.discount,
      available = payload_data.available,
      url = payload_data.url,
    }
  end

  -- Creates one alert for `event`/`match` (nil match = the no-match
  -- fallback alert). Returns true/false so a multi-match batch's failures
  -- don't stop the rest.
  local function create_alert(event, match)
    local ok, alert = pcall(function()
      return alert_manager:create(derive_alert_fields(event, match))
    end)

    if not ok then
      logger:error("Failed to create alert for event: {error}", { error = tostring(alert) })
      return false
    end

    return true
  end

  local event_manager = require("lib.resource_manager").new(models.Events, {
    fields_query_params = {
      "id",
      "source",
      "item_id",
      {
        key = "tags",
        map_clause = function(p)
          return string.format("%s = ANY(%s)", db.escape_literal(p.value), p.key)
        end,
      },
      {
        key = "created_after",
        map_clause = function(p)
          return "created_at >= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
        end,
      },
      {
        key = "created_before",
        map_clause = function(p)
          return "created_at <= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
        end,
      },
    },
    fields_search_params = { "source", "payload" },
    search_param = "search",
    updated_at_param = "updated_at",
    select_fields = "*, (select count(*) from alerts where alerts.event_id = events.id) as alert_count",
    on_create = function(event)
      local ok_match, matches = pcall(function()
        return rule_engine:match(build_match_context(event))
      end)

      if not ok_match then
        logger:error("Rule matching failed: {error}", { error = tostring(matches) })
        matches = {}
      end

      local any_failed = false

      if #matches == 0 then
        -- No rule matched: preserve the single undispatchable fallback
        -- alert (null pattern/rule_id) as an audit record.
        any_failed = not create_alert(event, nil)
      else
        for _, match in ipairs(matches) do
          if not create_alert(event, match) then
            any_failed = true
          end
        end
      end

      return not any_failed
    end,
  })

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.EVENTS_READ),
      with_error_handling("Failed to get events", "Failed to get events")
    )(function(self)
      return { status = 200, json = event_manager:search(self) }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.EVENTS_READ))(function(self)
      local item = event_manager:find(self.params.id)
      if not item then
        return { status = 404, json = { message = "Event not found", id = self.params.id } }
      end
      return { status = 200, json = { item = item } }
    end)
  )

  app:post(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.EVENTS_CREATE),
      with_json_body({
        { "payload", types.empty + types.valid_text },
        { "source", types.empty + types.valid_text },
        { "tags", types.empty + types.array_of(types.valid_text) },
        { "item_id", types.empty + types.valid_text + types.number },
      }),
      with_error_handling("Failed to create event", "Failed to create event")
    )(function(self)
      if type(self.params.tags) == "table" then
        self.params.tags = db.array(self.params.tags)
      end

      local item = event_manager:create(self.params)

      return { status = 202, json = { message = "Event queued", item = item } }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.EVENTS_DELETE),
      with_error_handling("Failed to delete event", "Failed to delete event")
    )(function(self)
      event_manager:delete(self.params.id)
      return { status = 200, json = { message = "Event deleted" } }
    end)
  )

  return {
    event_manager = event_manager,
    build_match_context = build_match_context,
  }
end

return Plugin
