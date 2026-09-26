-- Fired alerts: mostly read-only (+ delete) views over the alerts a rule
-- match produced. Alerts are created by "analyzer"-role workers, never as a
-- side effect of POST /api/observations: the embedded worker in-process
-- (server/workers/observe_pending_worker.lua, via shared/analyzer.lua), and
-- POST /api/alerts (below) for everything else - a narrow entry point: it lets a
-- caller that already decided a rule matched (and already made its own
-- cooldown decision) create the resulting alert directly - see
-- shared/watchtower_worker_core/worker_rule_matcher.lua, the standalone
-- worker's own client-side rule-matching path (shared/watchtower_worker_core/provider_http.lua's
-- M:create_alert), gated on its own alerts:create permission, separate from
-- alerts:read/update/delete (the seeded admin/operator roles have it).
local models = require("models")
local route_helpers = require("lib.routes")
local alert_queries = require("lib.alert_queries")
local export_response = require("lib.export_response")
local db = require("lapis.db")
local types = require("lapis.validate.types")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/alerts"

local VALID_SEVERITIES = { low = true, medium = true, high = true, critical = true }

local ALERTS_EXPORT_COLUMNS = {
  "id", "severity", "severity_value", "observation_id", "rule_id", "tags",
  "created_at", "updated_at", "source", "payload", "observable_id",
  "observable_type_id", "rule_name", "deliveries",
}

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
      "severity",
      "observation_id",
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
      route_helpers.created_after_param(),
      route_helpers.created_before_param(),
      {
        key = "observable_type_id",
        map_clause = function(p)
          return "observation_id in (select o.id from observations o join observables i on i.id = o.observable_id "
            .. "where i.observable_type_id = " .. db.escape_literal(p.value) .. ")"
        end,
      },
      {
        key = "observable_id",
        map_clause = function(p)
          return "observation_id in (select id from observations where observable_id = " .. db.escape_literal(p.value) .. ")"
        end,
      },
      -- Pure data filter (no matching/evaluation) - candidate alerts a
      -- notify pipeline pass might still need to enqueue a delivery for:
      -- no alert_deliveries row yet, or at least one row in status='error'
      -- (see lib/alert_queries.lua). Exposed as a filterable read so the
      -- standalone worker's own client-side
      -- notification_policy_matcher.lua can page through the candidate set
      -- without the server doing any policy matching on its behalf.
      {
        key = "needs_delivery",
        map_clause = function(p)
          return alert_queries.needs_delivery_sql("alerts")
        end,
      },
      -- Keyset-cursor filter (`after_id=<last id seen>` with `sort=id:asc`)
      -- for paging a set that shrinks while it's being paged (the
      -- needs_delivery candidates: enqueuing a delivery removes an alert
      -- from that set), where offset paging would skip rows.
      {
        key = "after_id",
        map_clause = function(p)
          return "alerts.id > " .. db.escape_literal(tonumber(p.value) or 0)
        end,
      },
    },
    fields_search_params = {
      {
        key = "source",
        map_clause = function(p)
          return string.format(
            "EXISTS (SELECT 1 FROM observations JOIN observables ON observables.id = observations.observable_id "
              .. "WHERE observations.id = alerts.observation_id AND %s)",
            route_helpers.escaped_like_clause("observables.name", p.value, "ILIKE")
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
    remove_fields_on_update = { "severity_value" },
    select_fields = "*, "
      .. "(select observables.name from observations join observables on observables.id = observations.observable_id "
      .. "where observations.id = alerts.observation_id) as source, "
      .. "(select properties::text from observations where observations.id = alerts.observation_id) as payload, "
      .. "(select observable_id from observations where observations.id = alerts.observation_id) as observable_id, "
      .. "(select observables.observable_type_id from observations join observables on observables.id = observations.observable_id "
      .. "where observations.id = alerts.observation_id) as observable_type_id, "
      .. "(select name from rules where rules.id = alerts.rule_id) as rule_name, "
      -- Delivery status is per-channel, not a scalar - see
      -- server/models/alert_deliveries.lua and its table comment in
      -- config/dataset/init.sql for why this lives in a sibling table
      -- rather than as columns on alerts itself.
      .. "(select json_agg(json_build_object('channel_id', ad.channel_id, 'notified_at', ad.notified_at, "
      .. "'status', ad.status)) from alert_deliveries ad where ad.alert_id = alerts.id) as deliveries",
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

  -- Downloads every alert matching the request's current filters/search/
  -- sort (no `from`/`size` in the request means get_db_query_params_from_
  -- request_params - see lib/routes.lua - never applies offset/limit, so
  -- this reuses alert_manager:search unfiltered by pagination) as JSON or
  -- CSV (?format=csv) - see lib/export_response.lua.
  app:get(
    base_path .. "/export",
    compose(
      require_auth,
      rbac:with(perms.ALERTS_READ),
      with_error_handling("Failed to export alerts", "Failed to export alerts")
    )(function(self)
      local result = alert_manager:search(self)
      return export_response.respond(self, result.items, ALERTS_EXPORT_COLUMNS, "alerts", "Alerts")
    end)
  )

  -- A narrow, validating create - the alert-creation decision (which rule
  -- matched, whether it's in cooldown) is entirely the caller's own; this
  -- route just checks the referenced observation exists and severity (if
  -- given) is one of the four allowed values, then inserts. Mirrors
  -- POST /api/observations's own validate-then-create shape
  -- (plugins/entities/observations_routes.lua).
  app:post(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.ALERTS_CREATE),
      with_json_body({
        { "observation_id", types.db_id },
        { "severity", types.empty + types.valid_text },
        { "rule_id", types.empty + types.db_id },
      }),
      with_error_handling("Failed to create alert", "Failed to create alert")
    )(function(self)
      local observation = models.Observations:find({ id = self.params.observation_id })
      if not observation then
        return { status = 404, json = { message = "Observation not found", observation_id = self.params.observation_id } }
      end

      if self.params.severity and self.params.severity ~= "" and not VALID_SEVERITIES[self.params.severity] then
        return { status = 400, json = { message = "severity must be one of low, medium, high, critical" } }
      end

      local ok, item = pcall(function()
        return alert_manager:create({
          observation_id = self.params.observation_id,
          severity = (self.params.severity and self.params.severity ~= "") and self.params.severity or nil,
          rule_id = (self.params.rule_id and self.params.rule_id ~= "") and self.params.rule_id or nil,
          tags = self.params.tags,
        })
      end)

      if not ok then
        -- alerts_rule_id_observation_id_idx (config/dataset/init.sql) is the
        -- DB-level backstop for the same "one alert per rule per
        -- observation" invariant the caller's own has_alert_for_observation
        -- pre-check already enforces (shared/watchtower_worker_core/
        -- worker_rule_matcher.lua) - a race hitting it here means the alert
        -- already exists, not a real failure, so respond as such rather
        -- than a 500.
        if tostring(item):find("alerts_rule_id_observation_id_idx", 1, true) then
          return { status = 200, json = { message = "Alert already exists for this rule and observation", duplicate = true } }
        end
        return { status = 500, json = { message = "Failed to create alert", error = tostring(item) } }
      end

      return { status = 201, json = { item = item } }
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
