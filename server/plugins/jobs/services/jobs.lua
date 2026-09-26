local db = require("lapis.db")
local unpack = table.unpack or unpack
local route_helpers = require("lib.routes")
local jsonb_query = require("lib.jsonb_query")
local M = {}

-- `type_managers[type_]` is `{ manager, apply }`:
--   manager - a resource_manager-shaped object (:find(id)/:update(id, fn))
--             for the rows this job type rolls up onto - observables for
--             type='observe'.
--   apply(d, winner) - mutates and returns the row `d` (from manager:find)
--             to reflect the winning job's status/worker/timestamps,
--             shaped for that manager's actual columns (observables and
--             alerts don't share a schema, unlike a rollup onto one
--             resource with one fixed shape).
-- A type with no entry here is simply never rolled up - report()/
-- report_error() still record the job row itself either way. type='analyze'
-- has no entry (its side effect - creating alerts - already happened
-- per-observable, before the aggregate report is ever sent, see
-- server/plugins/entities/services/reanalyze.lua). type='notify' also has
-- no entry here: a 'notify' job (the "evaluator"
-- role) enqueues onto the sibling alert_deliveries table from the worker's
-- own matching pass (shared/watchtower_worker_core/
-- notification_policy_matcher.lua), not as a side effect of this report - by
-- the time this module ever sees a type='notify' report, the only thing left
-- to do is record the job row,
-- exactly like every other type with no rollup entry. Actually sending a
-- notification is a fully separate role/pipeline
-- (plugins/notification_channels/services/delivery_queue.lua) that never
-- goes through this module's :report at all.
function M.new(job_model, type_managers)
  local instance = {
    _model = job_model,
    _type_managers = type_managers or {},
  }
  return setmetatable(instance, { __index = M })
end

-- The skeleton report() and report_error() share: UPDATE the worker's
-- in-flight ('triggering') row for this (worker_id, type, ref_id); if there
-- is none, INSERT a fresh one; then load the row and (unless `skip_rollup`)
-- roll it up onto its type's target. `update_sql`/`insert_sql` are format
-- strings taking the table name (%s), each with its own positional
-- parameter array. Runs in one transaction. Returns (job, rollup_target).
function M:_record_in_flight(type_, ref_id, skip_rollup, update_sql, update_params, insert_sql, insert_params)
  return route_helpers.with_transaction(function()
    local t = self._model:table_name()

    local rows = db.query(string.format(update_sql, t), unpack(update_params))
    if not rows[1] then
      rows = db.query(string.format(insert_sql, t), unpack(insert_params))
    end

    local job = self._model:load(rows[1])
    local rollup_target = nil
    if not skip_rollup then
      rollup_target = self:_rollup(type_, ref_id)
    end

    return job, rollup_target
  end)
end

-- Upserts the in-flight ('triggering') row for (worker_id, type, ref_id) to
-- `status`, then recomputes and rewrites the parent resource's rollup
-- status/worker/*_at fields from the current set of job rows for that
-- (type, ref_id). `status` is "triggering" or "acknowledged" (a row is
-- only ever lazily created when a worker reports one of those - there's no
-- separate "I see it but haven't started" report).
--
-- Tries a plain UPDATE-by-(worker_id, type, ref_id, status='triggering')
-- first, falling back to INSERT only if that touched nothing. NOT an
-- `INSERT ... ON CONFLICT (worker_id, type, ref_id) WHERE status =
-- 'triggering' DO UPDATE` - that was the first attempt at this, and it's a
-- real Postgres gotcha worth documenting: a *partial* unique index can only
-- ever serve as an ON CONFLICT arbiter for a row whose OWN values would
-- satisfy the index's predicate. Since this call very often writes
-- status = 'acknowledged' (never 'triggering'), Postgres silently skipped
-- the arbiter and inserted a duplicate row every single time instead of
-- updating the existing one - confirmed directly against a live DB before
-- switching to this UPDATE-first shape, which has no such restriction (a
-- plain UPDATE ... WHERE needs no index coverage to match rows).
--
-- jobs_active_unique_idx (worker_id, type, ref_id) WHERE status =
-- 'triggering' is still what makes this correct: at most one in-flight row
-- per worker+target can ever exist, so the UPDATE's WHERE clause is
-- guaranteed to match 0 or 1 rows. Once a row goes terminal
-- ('acknowledged'/'error') it falls out of that index and is never
-- touched again here: the next attempt at the same (worker_id, type,
-- ref_id) - e.g. a recurring scheduler task re-firing - goes through the
-- INSERT fallback and gets a fresh, independent row instead of colliding
-- with the finished one (see
-- plugins/scheduler/services/scheduler.lua's claim_next_batch, which relies
-- on exactly this to avoid the "duplicate key" crash a blanket unique
-- constraint used to cause on every firing after the first).
--
-- `retries` increments only when this worker re-reports the SAME status
-- it already had (a no-op retry, e.g. a client-side timeout resending an
-- already-successful request) - a genuine status change (forward
-- progress) never counts as a retry. Safe to compare the incoming
-- `status` directly against 'triggering' (rather than re-reading the
-- column) since the WHERE clause already guarantees the pre-update status
-- is 'triggering'.
--
-- `action` is what the worker actually did, reported at ack time (nil
-- for `triggering` reports). `message` carries the longer-form detail
-- behind that action, and is also what `report_error` writes on the
-- failure path. `result` is an arbitrary JSON payload (only type='test'
-- passes one today - see config/dataset/init.sql's comment on
-- jobs.result). All three are only written when non-nil, so a later report
-- that omits one doesn't erase a previously-recorded value.
--
-- Returns: job (Job instance), rollup_target (whatever the type's
-- ref_manager returns for :find/:update - nil if this job's type has no
-- registered ref_manager).
--
-- `skip_rollup` (optional, default falsy - every existing caller is
-- unaffected): skips the _rollup call entirely for this report. The one
-- caller that needs this today is plugins/scheduler/services/scheduler.lua's
-- one-job-per-firing report - it reports with ref_id = a scheduler_tasks.id,
-- not an observables.id, under the same type='observe' individual per-observable
-- observes use. Letting that go through the ordinary type='observe' rollup
-- (which looks ref_id up in `observables`) would either raise (no observable shares
-- that id - resource_manager:update 404s inside this same transaction) or,
-- worse, silently overwrite an unrelated observable that happens to share that
-- numeric id (observables and scheduler_tasks are independent id sequences).
function M:report(type_, ref_id, worker_id, status, action, message, result, skip_rollup)
  local action_v = action == nil and db.NULL or action
  local message_v = message == nil and db.NULL or message
  local result_v = result == nil and db.NULL or jsonb_query.encode(result)
  -- `skip_rollup` is only ever passed true by a scheduler-fired batch
  -- report (report_batch_result/report_batch_error, see this file's own
  -- header comment and jobs/plugin.lua's :status route param comment) -
  -- i.e. exactly when ref_id is a scheduler_tasks.id, not an observables.id.
  -- That's the same condition from_scheduler exists to record, so it's the
  -- value already threaded through this call for the INSERT fallback below
  -- to reuse, rather than a fresh lookup.
  local from_scheduler = not not skip_rollup

  return self:_record_in_flight(
    type_,
    ref_id,
    skip_rollup,
    [[
      UPDATE %s SET
        status = ?,
        taken_at = COALESCE(taken_at, CASE WHEN ? <> 'pending' THEN NOW() END),
        acked_at = COALESCE(acked_at, CASE WHEN ? = 'acknowledged' THEN NOW() END),
        action = COALESCE(?, action),
        message = COALESCE(?, message),
        result = COALESCE(?, result),
        retries = CASE WHEN ? = 'triggering' THEN retries + 1 ELSE retries END,
        updated_at = NOW()
      WHERE worker_id = ? AND type = ? AND ref_id = ? AND status = 'triggering'
      RETURNING *
    ]],
    { status, status, status, action_v, message_v, result_v, status, worker_id, type_, ref_id },
    -- No in-flight row to update - a brand-new attempt. The ordinary
    -- interval-polling path never pre-creates a row at all; the scheduler's
    -- claim_next_batch does, but already as 'triggering', so that case is
    -- caught by the UPDATE above instead. A late report that misses the
    -- UPDATE because reap_stale already flipped the in-flight row to
    -- 'error' (see that function's own header comment) lands here too -
    -- from_scheduler must still be set correctly on that fresh row, not
    -- left at its DEFAULT FALSE, or it mistags a scheduler-fired batch job
    -- as an ordinary per-observable one (see M:_rollup/reap_stale's own
    -- from_scheduler handling and GET /api/jobs' observable_type_id filter).
    [[
      INSERT INTO %s (worker_id, type, ref_id, from_scheduler, status, taken_at, acked_at, action, message, result, retries)
      VALUES (
        ?, ?, ?, ?, ?,
        CASE WHEN ? <> 'pending' THEN NOW() END,
        CASE WHEN ? = 'acknowledged' THEN NOW() END,
        ?, ?, ?, 0
      )
      RETURNING *
    ]],
    { worker_id, type_, ref_id, from_scheduler, status, status, status, action_v, message_v, result_v }
  )
end

-- Records that `worker_id` hit a local failure for this (type, ref_id)
-- (e.g. the observe failed - a site/network problem, not a
-- server-communication problem, since the worker successfully reached
-- the server to report this). Sets `status` to "error" alongside
-- `error_at` and `message` (the reported failure reason), and always
-- increments `retries` (every error is an unsuccessful attempt).
--
-- Same UPDATE-first idiom as report() above, for the same reason: an
-- `INSERT ... ON CONFLICT (...) WHERE status = 'triggering'` can't ever
-- match here since this always writes status = 'error', which a partial
-- index's arbiter can't detect a conflict for (see report()'s header
-- comment for the full story). A plain UPDATE ... WHERE has no such
-- restriction, and structurally guarantees an already-"acknowledged" row
-- can never be downgraded by a late/stray error report - it simply won't
-- match this WHERE clause. "error" is terminal, same as "acknowledged":
-- once this fires, the row falls out of jobs_active_unique_idx, so the
-- worker's *next* attempt at the same (worker_id, type, ref_id) - whether
-- a retry of this attempt or a later scheduler firing - gets its own
-- fresh row via the INSERT fallback below rather than resurrecting this
-- one.
-- `skip_rollup`: see M:report's header comment - same reasoning applies to
-- the whole-batch-failure path.
function M:report_error(type_, ref_id, worker_id, message, skip_rollup)
  -- See M:report's identical derivation above - skip_rollup is only ever
  -- true for a scheduler-fired batch report, the same condition
  -- from_scheduler records.
  local from_scheduler = not not skip_rollup

  return self:_record_in_flight(
    type_,
    ref_id,
    skip_rollup,
    [[
      UPDATE %s SET
        status = 'error',
        error_at = NOW(),
        message = ?,
        retries = retries + 1,
        updated_at = NOW()
      WHERE worker_id = ? AND type = ? AND ref_id = ? AND status = 'triggering'
      RETURNING *
    ]],
    { message, worker_id, type_, ref_id },
    -- Same late-report-after-reap_stale INSERT fallback as M:report above -
    -- from_scheduler must be set explicitly here too.
    [[
      INSERT INTO %s (worker_id, type, ref_id, from_scheduler, status, taken_at, error_at, message, retries)
      VALUES (?, ?, ?, ?, 'error', NOW(), NOW(), ?, 0)
      RETURNING *
    ]],
    { worker_id, type_, ref_id, from_scheduler, message }
  )
end

-- Picks the job row that "wins" the rollup: the most recent attempt across
-- every worker that's ever touched this (type, ref_id), full stop.
-- Rewrites the type's rollup target via `type_managers[type_].apply` - a
-- no-op (returns nil) if this job type has no registered rollup target.
--
-- Deliberately NOT status-priority-based (an older version of this ranked
-- acknowledged > triggering > error > pending) - now that a single
-- (worker_id, type, ref_id) can accumulate many independent historical
-- rows over successive attempts (see jobs_active_unique_idx and
-- report()/report_error()'s comments), priority-first would let one lucky
-- acknowledged row from attempt #1 permanently outrank and mask every
-- failure since, freezing e.g. observables.last_observe_status on a stale success
-- forever. "Most recent wins" keeps the rollup meaning what its name
-- says: the current state, not the best state ever seen.
--
-- `from_scheduler = false`: a rollup target is an observable, so only rows
-- whose ref_id IS an observables.id count - a scheduler-fired row's ref_id is
-- a scheduler_tasks.id, which can numerically collide with an unrelated
-- observable's id and would otherwise be picked as its "latest" attempt.
function M:_rollup(type_, ref_id)
  local target = self._type_managers[type_]
  if not target then
    return nil
  end

  local rows = db.query(
    string.format(
      [[
    SELECT * FROM %s
    WHERE type = ? AND ref_id = ? AND from_scheduler = false
    ORDER BY created_at DESC, id DESC
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

  local _, item = target.manager:update(ref_id, function(d)
    return target.apply(d, winner)
  end)

  return item
end

-- Resets any 'triggering' row whose `taken_at` is older than
-- `timeout_seconds` back to 'error' - see jobs_active_unique_idx's own
-- comment in config/dataset/init.sql. A claim whose worker crashed, hung,
-- or lost connectivity before ever reporting would otherwise sit in
-- 'triggering' forever, permanently blocking any future claim for that same
-- (worker_id, type, ref_id) - this is the only thing that ever moves such a
-- row out of that state. Called periodically by "scheduler"-role workers
-- only - see shared/watchtower_worker_core/pollers/reap_stale.lua.
--
-- Same UPDATE-only shape as report_error (status='error' can never be an
-- ON CONFLICT arbiter target for the 'triggering'-only partial index - see
-- report()'s header comment above for the full story), except this can
-- reap more than one row per call, so it loops the result set for rollups
-- instead of handling a single row.
--
-- Skips _rollup for from_scheduler=true rows for the same reason report()/
-- report_error() do: that row's ref_id is a scheduler_tasks.id, not
-- whatever the type's registered rollup target expects.
function M:reap_stale(timeout_seconds)
  return route_helpers.with_transaction(function()
    local t = self._model:table_name()

    local rows = db.query(
      string.format(
        [[
      UPDATE %s SET
        status = 'error',
        error_at = NOW(),
        message = 'reaped: no report within ' || ? || 's of being claimed',
        retries = retries + 1,
        updated_at = NOW()
      WHERE status = 'triggering' AND taken_at < NOW() - (? || ' seconds')::interval
      RETURNING *
    ]],
        t
      ),
      timeout_seconds,
      timeout_seconds
    )

    for _, row in ipairs(rows) do
      if not row.from_scheduler then
        self:_rollup(row.type, row.ref_id)
      end
    end

    return rows
  end)
end

function M:list_for(type_, ref_id)
  return self._model:select(
    "where type = ? and ref_id = ? order by created_at asc",
    type_,
    ref_id
  )
end

-- Per-worker totals + a breakdown by job status, optionally scoped to one
-- `type_`. There's no separate `workers` registry table involved here on
-- purpose - this is a plain GROUP BY over `jobs`, pivoted in Lua into one
-- row per worker: { worker_id, total, by_status = {status = count} }.
-- A NULL worker_id - a scheduler-queued job not yet claimed by anyone, see
-- jobs' own worker_id column comment in config/dataset/init.sql - is a
-- routine, non-rare state, not something to drop from this response: it's
-- surfaced under the sentinel worker_id UNASSIGNED_WORKER_ID rather than
-- left as a real Lua nil, since nil can't be used as a table key here
-- (by_worker[nil] = entry raises "table index is nil", and even if it
-- didn't, table.insert(order, nil) is a no-op that would silently drop
-- the bucket from `order`, and so from this response, since the final
-- loop below only ever visits `order` via ipairs).
-- Worker self-reported identity (connection type, version, capabilities,
-- last-seen) lives separately, see services/workers.lua.
local UNASSIGNED_WORKER_ID = "unassigned"

function M:stats(type_)
  local rows
  if type_ then
    rows = db.query(
      string.format(
        [[
      SELECT worker_id, status, COUNT(*) AS count
      FROM %s
      WHERE type = ?
      GROUP BY worker_id, status
      ORDER BY worker_id
    ]],
        self._model:table_name()
      ),
      type_
    )
  else
    rows = db.query(string.format(
      [[
      SELECT worker_id, status, COUNT(*) AS count
      FROM %s
      GROUP BY worker_id, status
      ORDER BY worker_id
    ]],
      self._model:table_name()
    ))
  end

  local by_worker = {}
  local order = {}
  for _, row in ipairs(rows) do
    local worker_key = row.worker_id or UNASSIGNED_WORKER_ID
    local entry = by_worker[worker_key]
    if not entry then
      entry = { worker_id = worker_key, total = 0, by_status = {} }
      by_worker[worker_key] = entry
      table.insert(order, worker_key)
    end
    local count = tonumber(row.count)
    entry.by_status[row.status] = count
    entry.total = entry.total + count
  end

  local result = {}
  for _, worker_id in ipairs(order) do
    table.insert(result, by_worker[worker_id])
  end
  return result
end

return M
