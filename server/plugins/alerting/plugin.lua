-- Fired alerts: read-only (+ delete) views over the alerts a rule match
-- produced. No POST/PUT of alert content - POST /api/events (see
-- plugins/events/plugin.lua) is the sole entry point that creates alerts,
-- resolved synchronously by the rule engine. Ported from pibuzz's
-- alert_manager wiring in application/main.lua.
--
-- Status-mutation routes (PUT /api/alerts/:id/:status, /ack, /error) are
-- deferred to when a notification worker exists to drive them (a `jobs`
-- row of type='notify' reporting via plugins/jobs/services/jobs.lua) -
-- not part of this port's scope (see config/dataset/init.sql's comment on
-- the `jobs.type` column). Until then a fired alert's status/monitor/*_at
-- columns stay at their 'pending'/null defaults.
local models = require("models")
local route_helpers = require("lib.routes")
local db = require("lapis.db")

local compose = route_helpers.compose
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/alerts"

local Plugin = {
  name = "alerting",
  dependencies = { "security" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  local alert_manager = require("lib.resource_manager").new(models.Alerts, {
    fields_query_params = {
      "id",
      "status",
      "priority",
      "pattern",
      "event_id",
      {
        key = "tags",
        map_clause = function(p)
          return string.format("%s = ANY(%s)", db.escape_literal(p.value), p.key)
        end,
      },
      {
        key = "rule_id",
        map_clause = function(p)
          if p.value == "none" then
            return "rule_id IS NULL"
          elseif p.value == "matched" then
            return "rule_id IS NOT NULL"
          end
          return "rule_id = " .. db.escape_literal(p.value)
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
    fields_search_params = {
      "status",
      {
        key = "source",
        map_clause = function(p)
          return string.format(
            "EXISTS (SELECT 1 FROM events WHERE events.id = alerts.event_id AND %s)",
            route_helpers.escaped_like_clause("events.source", p.value, "ILIKE")
          )
        end,
      },
      {
        key = "tags",
        map_clause = function(p)
          return string.format(
            "EXISTS (SELECT 1 FROM unnest(tags) AS tag WHERE %s)",
            route_helpers.escaped_like_clause("tag", p.value, "ILIKE")
          )
        end,
      },
    },
    search_param = "search",
    updated_at_param = "updated_at",
    remove_fields_on_update = { "priority_value" },
    select_fields = "*, "
      .. "(select source from events where events.id = alerts.event_id) as source, "
      .. "(select payload from events where events.id = alerts.event_id) as payload, "
      .. "(select item_id from events where events.id = alerts.event_id) as item_id, "
      .. "(select name from rules where rules.id = alerts.rule_id) as rule_name",
  })

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.ALERTS_READ),
      with_error_handling("Failed to get alerts", "Failed to get alerts")
    )(function(self)
      return { status = 200, json = alert_manager:search(self) }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.ALERTS_READ))(function(self)
      local item = alert_manager:find(self.params.id)
      if not item then
        return { status = 404, json = { message = "Alert not found", id = self.params.id } }
      end
      return { status = 200, json = { item = item } }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.ALERTS_DELETE),
      with_error_handling("Failed to delete alert", "Failed to delete alert")
    )(function(self)
      alert_manager:delete(self.params.id)
      return { status = 200, json = { message = "Alert deleted" } }
    end)
  )

  return {
    alert_manager = alert_manager,
  }
end

return Plugin
