local db = require("lapis.db")
local route_helpers = require("lib.routes")
local M = {}

-- `type_managers[type_]` is `{ manager, apply }`:
--   manager - a resource_manager-shaped object (:find(id)/:update(id, fn))
--             for the rows this job type rolls up onto - items for
--             type='scrape', the alerting plugin's alert_manager for a
--             future type='notify' (not wired up yet, see
--             config/dataset/init.sql's comment on jobs.type).
--   apply(d, winner) - mutates and returns the row `d` (from manager:find)
--             to reflect the winning job's status/monitor/timestamps,
--             shaped for that manager's actual columns (items and alerts
--             don't share a schema, unlike pibuzz's deliveries.lua, which
--             only ever rolled up onto one resource with one fixed shape).
-- A type with no entry here is simply never rolled up - report()/
-- report_error() still record the job row itself either way.
function M.new(job_model, type_managers)
  local instance = {
    _model = job_model,
    _type_managers = type_managers or {},
  }
  return setmetatable(instance, { __index = M })
end

-- Upserts the (monitor_id, type, ref_id) row to `status`, then recomputes
-- and rewrites the parent resource's rollup status/monitor/*_at fields
-- from the current set of job rows for that (type, ref_id). `status` is
-- "triggering" or "acknowledged" (a row is only ever lazily created when a
-- monitor reports one of those - there's no separate "I see it but
-- haven't started" report).
--
-- `retries` increments only when this monitor re-reports the SAME status
-- it already had (a no-op retry, e.g. a client-side timeout resending an
-- already-successful request) - a genuine status change (forward
-- progress) never counts as a retry.
--
-- `action` is what the monitor actually did, reported at ack time (nil
-- for `triggering` reports). `message` carries the longer-form detail
-- behind that action, and is also what `report_error` writes on the
-- failure path. Both are only written when non-nil, so a later report
-- that omits one doesn't erase a previously-recorded value.
--
-- Returns: job (Job instance), rollup_target (whatever the type's
-- ref_manager returns for :find/:update - nil if this job's type has no
-- registered ref_manager).
function M:report(type_, ref_id, monitor_id, status, action, message)
  return route_helpers.with_transaction(function()
    local t = self._model:table_name()

    local rows = db.query(
      string.format(
        [[
      INSERT INTO %s (monitor_id, type, ref_id, status, taken_at, acked_at, action, message, retries)
      VALUES (
        ?, ?, ?, ?,
        CASE WHEN ? <> 'pending' THEN NOW() END,
        CASE WHEN ? = 'acknowledged' THEN NOW() END,
        ?,
        ?,
        0
      )
      ON CONFLICT (monitor_id, type, ref_id) DO UPDATE SET
        status = EXCLUDED.status,
        taken_at = COALESCE(%s.taken_at, EXCLUDED.taken_at),
        acked_at = COALESCE(%s.acked_at, EXCLUDED.acked_at),
        action = COALESCE(EXCLUDED.action, %s.action),
        message = COALESCE(EXCLUDED.message, %s.message),
        retries = CASE WHEN %s.status = EXCLUDED.status THEN %s.retries + 1 ELSE %s.retries END,
        updated_at = NOW()
      RETURNING *
    ]],
        t,
        t,
        t,
        t,
        t,
        t,
        t,
        t
      ),
      monitor_id,
      type_,
      ref_id,
      status,
      status,
      status,
      action == nil and db.NULL or action,
      message == nil and db.NULL or message
    )

    local job = self._model:load(rows[1])
    local rollup_target = self:_rollup(type_, ref_id)

    return job, rollup_target
  end)
end

-- Records that `monitor_id` hit a local failure for this (type, ref_id)
-- (e.g. the scrape failed - a site/network problem, not a
-- server-communication problem, since the monitor successfully reached
-- the server to report this). Sets `status` to "error" alongside
-- `error_at` and `message` (the reported failure reason), and always
-- increments `retries` (every error is an unsuccessful attempt).
--
-- An already-"acknowledged" row keeps that status - a late/stray error
-- report must never downgrade a job that already succeeded. Nothing else
-- clears "error": the monitor's next `report` overwrites it via its own
-- `status = EXCLUDED.status`, so a retry recovers on its own.
function M:report_error(type_, ref_id, monitor_id, message)
  return route_helpers.with_transaction(function()
    local t = self._model:table_name()

    local rows = db.query(
      string.format(
        [[
      INSERT INTO %s (monitor_id, type, ref_id, status, taken_at, error_at, message, retries)
      VALUES (?, ?, ?, 'error', NOW(), NOW(), ?, 0)
      ON CONFLICT (monitor_id, type, ref_id) DO UPDATE SET
        status = CASE WHEN %s.status = 'acknowledged' THEN %s.status ELSE 'error' END,
        error_at = NOW(),
        message = EXCLUDED.message,
        retries = %s.retries + 1,
        updated_at = NOW()
      RETURNING *
    ]],
        t,
        t,
        t,
        t
      ),
      monitor_id,
      type_,
      ref_id,
      message
    )

    local job = self._model:load(rows[1])
    local rollup_target = self:_rollup(type_, ref_id)

    return job, rollup_target
  end)
end

-- Picks the job row that "wins" the rollup: highest status priority first
-- (acknowledged > triggering > error > pending), tie-broken by whichever
-- timestamp landed first among rows sharing that top priority. Rewrites
-- the type's rollup target via `type_managers[type_].apply` - a no-op
-- (returns nil) if this job type has no registered rollup target.
--
-- "error" outranks only "pending": a monitor still actively attempting
-- the job says more about where it stands than one that already gave up,
-- so "error" surfaces at the rollup level only once nothing but failures
-- is left.
function M:_rollup(type_, ref_id)
  local target = self._type_managers[type_]
  if not target then
    return nil
  end

  local rows = db.query(
    string.format(
      [[
    SELECT * FROM %s
    WHERE type = ? AND ref_id = ?
    ORDER BY
      CASE status
        WHEN 'acknowledged' THEN 4
        WHEN 'triggering' THEN 3
        WHEN 'error' THEN 2
        ELSE 1
      END DESC,
      COALESCE(acked_at, taken_at, updated_at) ASC
    LIMIT 1
  ]],
      self._model:table_name()
    ),
    type_,
    ref_id
  )

  local winner = rows[1]

  if not winner or winner.status == "pending" then
    return target.manager:find(ref_id)
  end

  local ok, item = target.manager:update(ref_id, function(d)
    return target.apply(d, winner)
  end)

  return item
end

function M:list_for(type_, ref_id)
  return self._model:select(
    "where type = ? and ref_id = ? order by created_at asc",
    type_,
    ref_id
  )
end

-- Per-monitor totals + a breakdown by job status, optionally scoped to one
-- `type_`. There's no separate `monitors` registry table involved here on
-- purpose - this is a plain GROUP BY over `jobs`, pivoted in Lua into one
-- row per monitor: { monitor_id, total, by_status = {status = count} }.
-- Monitor self-reported identity (connection type, version, capabilities,
-- last-seen) lives separately, see services/monitors.lua.
function M:stats(type_)
  local rows
  if type_ then
    rows = db.query(
      string.format(
        [[
      SELECT monitor_id, status, COUNT(*) AS count
      FROM %s
      WHERE type = ?
      GROUP BY monitor_id, status
      ORDER BY monitor_id
    ]],
        self._model:table_name()
      ),
      type_
    )
  else
    rows = db.query(string.format(
      [[
      SELECT monitor_id, status, COUNT(*) AS count
      FROM %s
      GROUP BY monitor_id, status
      ORDER BY monitor_id
    ]],
      self._model:table_name()
    ))
  end

  local by_monitor = {}
  local order = {}
  for _, row in ipairs(rows) do
    local entry = by_monitor[row.monitor_id]
    if not entry then
      entry = { monitor_id = row.monitor_id, total = 0, by_status = {} }
      by_monitor[row.monitor_id] = entry
      table.insert(order, row.monitor_id)
    end
    local count = tonumber(row.count)
    entry.by_status[row.status] = count
    entry.total = entry.total + count
  end

  local result = {}
  for _, monitor_id in ipairs(order) do
    table.insert(result, by_monitor[monitor_id])
  end
  return result
end

return M
