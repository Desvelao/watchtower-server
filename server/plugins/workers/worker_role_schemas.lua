-- Fixed, hardcoded roles a worker can self-report (a worker can
-- report more than one at once - e.g. the embedded worker both observes
-- and analyzes in the same process). Unlike observable_types, these are NOT
-- user-editable via the UI/API - they're architectural roles, not domain
-- entities, so the set and each role's property schema are fixed in code
-- here (mirrored by hand in public/src/plugins/workers/workerRoleSchemas.js
-- - keep both in sync, same convention as constants/permissions.js).
--
-- Each role's property list is in the same PropertyDefinition shape
-- lib/property_schema.lua already validates against for observable types
-- ({name, label, type, multiple, required, searchable, validations}) - so
-- a worker's self-reported `properties` (see plugins/workers/plugin.lua's
-- heartbeat route) is validated the exact same way, against the
-- concatenation of every role the worker declares in `roles`.
local M = {}

M.WORKER_ROLES = require("watchtower_worker_core.roles").ROLES

M.PROPERTY_SCHEMAS = {
  -- Worker's own metadata already lives in workers' existing fixed
  -- columns (connection_type/capabilities/config/version/
  -- uptime_seconds) - nothing new needed in `properties` for it today.
  observer = {},

  -- observations_analyzed is a real, self-reported counter (incremented
  -- by server/workers/observe_pending_worker.lua each time it runs an
  -- observation through shared/analyzer.lua) - not a placeholder metric.
  analyzer = {
    { name = "observations_analyzed", label = "Observations analyzed", type = "number", required = false },
  },

  -- deliveries_sent is a real, self-reported counter (incremented by
  -- shared/watchtower_worker_core/pollers/notify.lua each time this worker's notify tick
  -- successfully sends one alert_deliveries row) - not a placeholder
  -- metric. Purely a sender now - it knows nothing about
  -- notification_policies (see the "evaluator" role
  -- below).
  deliver = {
    { name = "deliveries_sent", label = "Deliveries sent", type = "number", required = false },
  },

  -- jobs_fired is a real, self-reported counter (incremented each time this
  -- worker's scheduler tick fires a due plugins/scheduler row - see
  -- shared/watchtower_worker_core/processors.lua's do_fire_due_tasks and
  -- server/workers/observe_pending_worker.lua's poll_and_fire_due_tasks) -
  -- not a placeholder metric.
  scheduler = {
    { name = "jobs_fired", label = "Scheduler tasks fired", type = "number", required = false },
  },

  -- deliveries_enqueued is a real, self-reported counter (incremented each
  -- time this worker's evaluate tick matches alerts against
  -- notification_policies and enqueues deliveries - see
  -- shared/watchtower_worker_core/pollers/evaluate.lua and
  -- shared/watchtower_worker_core/notification_policy_matcher.lua) - not a
  -- placeholder metric. Purely an
  -- evaluator - it enqueues onto alert_deliveries but never sends anything
  -- itself (see the "deliver" role above).
  evaluator = {
    { name = "deliveries_enqueued", label = "Deliveries enqueued", type = "number", required = false },
  },
}

return M
