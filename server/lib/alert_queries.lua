-- SQL for the "alerts that may still need a delivery enqueued" candidate
-- set, shared by everything on the server side that reads it: the
-- filterable GET /api/alerts?needs_delivery=true (which the standalone
-- worker's evaluator pages through) and the embedded
-- worker's own in-process candidate pager. Data access only - which alerts
-- match which notification policies is decided worker-side, never here.
local db = require("lapis.db")

local M = {}

-- SQL predicate over the alerts table (under `alias`, default "alerts"):
-- the alert has no alert_deliveries row yet, or at least one in
-- status='error' (which the next enqueue resets to 'pending' for retry). An
-- alert whose every attempted channel already succeeded (or is still
-- pending/triggering) drops out - accepted limitation: a policy edited to
-- add a channel after an alert's last full success won't retroactively
-- reach that alert.
function M.needs_delivery_sql(alias)
  alias = alias or "alerts"
  return string.format(
    "(NOT EXISTS (SELECT 1 FROM alert_deliveries ad WHERE ad.alert_id = %s.id) "
      .. "OR EXISTS (SELECT 1 FROM alert_deliveries ad WHERE ad.alert_id = %s.id AND ad.status = 'error'))",
    alias,
    alias
  )
end

-- One keyset page (ascending id, ids strictly greater than `after_id`, at
-- most `limit` rows) of the candidate alerts, carrying exactly the fields a
-- notification policy can match on (see
-- shared/rule_engine/notification_policy_allowed_fields.lua): the alert's
-- severity/tags/rule_id plus the observable_id it fired for (alerts has no
-- observable_id column of its own - joined in via its observation). A
-- keyset cursor, not an offset: enqueuing removes rows from the candidate
-- set while it is being paged, which would make offset paging skip rows.
function M.candidate_alerts_page(after_id, limit)
  return db.query(
    [[
    SELECT a.id, a.severity, a.tags, a.rule_id, o.observable_id AS observable_id
    FROM alerts a
    JOIN observations o ON o.id = a.observation_id
    WHERE a.id > ? AND ]] .. M.needs_delivery_sql("a") .. [[

    ORDER BY a.id ASC
    LIMIT ?
  ]],
    after_id or 0,
    limit
  )
end

return M
