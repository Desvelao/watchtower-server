-- Sender-side claim/report cycle for the durable alert_deliveries queue
-- (see that table's own header comment in config/dataset/init.sql) - the
-- "deliver" worker role's entire job. Fully independent of
-- scheduler_tasks/jobs: enqueuing (the "evaluator"
-- role's worker-side matching, shared/watchtower_worker_core/
-- notification_policy_matcher.lua) and sending (this file) share no state
-- beyond the alert_deliveries rows themselves.
local db = require("lapis.db")

local M = {}

local DEFAULT_BATCH_SIZE = 200

function M.new(notification_channels_model)
  return setmetatable({ _notification_channels = notification_channels_model }, { __index = M })
end

-- Atomically claims up to `limit` 'pending' alert_deliveries rows (oldest
-- first), assigning them to worker_id and advancing to 'triggering'.
-- FOR UPDATE SKIP LOCKED is what makes this genuinely concurrent-safe
-- across multiple senders - unlike the old design (a single scheduler-fired
-- job claimed once by one worker), any number of "deliver" workers can now
-- drain this queue in parallel without claiming the same row twice. Returns
-- {groups = [{channel, alerts, alert_ids}, ...]} - the same shape
-- shared/watchtower_worker_core/pollers/notify.lua already consumed under the old design, so
-- its send step needs no change; nil when nothing is pending (same "nil,
-- not an empty groups table" contract
-- plugins/scheduler/services/scheduler.lua's claim_next_batch already uses,
-- so PUT /api/alert_deliveries/claim's JSON response omits `item` exactly
-- like PUT /api/scheduler/claim's already does).
function M:claim_batch(worker_id, limit)
  limit = limit or DEFAULT_BATCH_SIZE

  local claimed = db.query([[
    UPDATE alert_deliveries
       SET status = 'triggering', worker_id = ?, taken_at = NOW(), updated_at = NOW()
     WHERE (alert_id, channel_id) IN (
       SELECT alert_id, channel_id FROM alert_deliveries
        WHERE status = 'pending'
        ORDER BY updated_at ASC
        LIMIT ?
        FOR UPDATE SKIP LOCKED
     )
    RETURNING alert_id, channel_id
  ]], worker_id, limit)

  if #claimed == 0 then
    return nil
  end

  local alert_ids, seen_alert = {}, {}
  local channel_order, seen_channel = {}, {}
  for _, row in ipairs(claimed) do
    if not seen_alert[row.alert_id] then
      seen_alert[row.alert_id] = true
      table.insert(alert_ids, row.alert_id)
    end
    if not seen_channel[row.channel_id] then
      seen_channel[row.channel_id] = true
      table.insert(channel_order, row.channel_id)
    end
  end

  -- Same enrichment shape plugins/alerting/plugin.lua's GET /api/alerts and
  -- the evaluator's own alert query already use, needed so
  -- shared/watchtower_worker_core/notification_senders.lua's per-alert templates can interpolate
  -- any alert.<column> plus alert.payload.<field>.
  local alerts = db.query([[
    SELECT a.*, o.observable_id AS observable_id, o.properties::text AS payload,
           i.name AS observable_name, r.name AS rule_name
    FROM alerts a
    JOIN observations o ON o.id = a.observation_id
    JOIN observables i ON i.id = o.observable_id
    LEFT JOIN rules r ON r.id = a.rule_id
    WHERE a.id = any(?)
  ]], db.array(alert_ids))

  local alert_by_id = {}
  for _, alert in ipairs(alerts) do
    alert_by_id[alert.id] = alert
  end

  -- Goes through the model (not a raw select) so notification_channels.lua's
  -- decorate_methods hook attaches each channel's .options subtype row -
  -- shared/watchtower_worker_core/notification_senders.lua reads channel.options.* directly.
  local channels = self._notification_channels:select("where id = any(?)", db.array(channel_order))
  local channel_by_id = {}
  for _, channel in ipairs(channels) do
    channel_by_id[channel.id] = channel
  end

  local alerts_by_channel, alert_ids_by_channel = {}, {}
  for _, row in ipairs(claimed) do
    local alert = alert_by_id[row.alert_id]
    if alert then
      if not alerts_by_channel[row.channel_id] then
        alerts_by_channel[row.channel_id] = {}
        alert_ids_by_channel[row.channel_id] = {}
      end
      table.insert(alerts_by_channel[row.channel_id], alert)
      table.insert(alert_ids_by_channel[row.channel_id], row.alert_id)
    end
  end

  -- alerts_by_channel[channel_id] is only ever populated when at least one
  -- claimed row's alert still exists (see the loop above) - a channel whose
  -- every claimed alert was cascade-deleted between the UPDATE and this
  -- enrichment SELECT (alert_deliveries.alert_id is ON DELETE CASCADE from
  -- alerts, and alerts are deletable via the alerting plugin's DELETE route)
  -- simply has no entry here. Skip such a channel entirely rather than
  -- emitting a group with a populated channel but nil alerts/alert_ids - a
  -- shape notification_senders.lua/pollers/notify.lua don't account for.
  local groups = {}
  for _, channel_id in ipairs(channel_order) do
    local channel = channel_by_id[channel_id]
    if channel and alerts_by_channel[channel_id] then
      table.insert(groups, {
        channel = channel,
        alerts = alerts_by_channel[channel_id],
        alert_ids = alert_ids_by_channel[channel_id],
      })
    end
  end

  return { groups = groups }
end

-- Enqueues (or resets from 'error' back to) a single 'pending' row for
-- (alert_id, channel_id) - called by the embedded worker's matcher directly
-- (in-process) and by the standalone worker's own narrow write path
-- (POST /api/alert_deliveries, driven by
-- shared/watchtower_worker_core/notification_policy_matcher.lua's
-- client-side matching - see that module's header comment for why the
-- matching itself never happens server-side). Returns true if a row was
-- inserted/reset, false if an existing non-error row was left untouched
-- (already pending/triggering/sent).
function M:enqueue(alert_id, channel_id)
  local rows = db.query([[
    INSERT INTO alert_deliveries (alert_id, channel_id, status, updated_at)
    VALUES (?, ?, 'pending', NOW())
    ON CONFLICT (alert_id, channel_id) DO UPDATE
      SET status = 'pending', updated_at = NOW()
      WHERE alert_deliveries.status = 'error'
    RETURNING alert_id
  ]], alert_id, channel_id)
  return rows[1] ~= nil
end

-- Applies a batch's reported channel_results (see
-- shared/watchtower_worker_core/notification_senders.lua/shared/watchtower_worker_core/pollers/notify.lua -
-- {channel_id, alert_id, ok, reason?}, one per (channel, alert) MESSAGE
-- actually sent) directly onto the (alert_id, channel_id) rows this
-- worker_id claimed - guarded on status='triggering' so a report can only
-- resolve a row this same worker actually claimed, never one that's already
-- terminal or claimed by someone else.
function M:report(channel_results, worker_id)
  for _, r in ipairs(channel_results or {}) do
    db.query(
      [[
      UPDATE alert_deliveries
         SET status = ?,
             notified_at = CASE WHEN ? THEN NOW() ELSE NULL END,
             error_message = ?,
             updated_at = NOW()
       WHERE alert_id = ? AND channel_id = ? AND worker_id = ? AND status = 'triggering'
    ]],
      r.ok and "sent" or "error",
      r.ok and true or false,
      (not r.ok) and tostring(r.reason) or db.NULL,
      r.alert_id,
      r.channel_id,
      worker_id
    )
  end
end

-- Periodic housekeeping, the "evaluator" role's counterpart to
-- plugins/jobs/services/jobs.lua's own reap_stale: resets any
-- alert_deliveries row stuck in 'triggering' past `timeout_seconds` back to
-- 'error' - a claim (see M:claim_batch above) whose "deliver"-role worker
-- crashed/hung/lost connectivity before M:report ran would otherwise sit in
-- 'triggering' forever, never sent and never retried. "evaluator" owns this
-- (not "deliver") for the same reason "scheduler" - not "observer"/
-- "analyzer" - owns jobs' own reap_stale: it's the role that *produces*
-- this queue's rows (via its own enqueue pass, M:enqueue above), mirroring
-- scheduler's relationship to `jobs`.
--
-- No route_helpers.with_transaction wrapper (unlike jobs.reap_stale): a
-- single UPDATE ... RETURNING is already atomic, and there's no per-row
-- rollup step here to keep in the same transaction (jobs' own `_rollup` is
-- a jobs-only concept). worker_id is left untouched - a historical trace of
-- the last claimant, same as jobs.reap_stale leaves its own worker_id. No
-- retries-style column to bump either: the next M:enqueue upsert for this
-- same (alert_id, channel_id) already resets an 'error' row back to
-- 'pending' for retry, same as it always has.
function M:reap_stale(timeout_seconds)
  return db.query(
    [[
    UPDATE alert_deliveries SET
      status = 'error',
      error_message = 'reaped: no report within ' || ? || 's of being claimed',
      updated_at = NOW()
    WHERE status = 'triggering' AND taken_at < NOW() - (? || ' seconds')::interval
    RETURNING *
  ]],
    timeout_seconds,
    timeout_seconds
  )
end

return M
