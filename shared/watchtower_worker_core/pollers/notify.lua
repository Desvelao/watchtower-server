-- Executes one claim-batch of the alert_deliveries queue per call: claims
-- up to a batch of 'pending' rows directly from the queue (see
-- plugins/notification_channels/services/delivery_queue.lua's
-- claim_batch/report - fully independent of scheduler_tasks/jobs, unlike
-- the old design this replaced), dispatches each resolved channel group via
-- shared/watchtower_worker_core/notification_senders.lua, and reports each row's own outcome back
-- onto the alert_deliveries rows this worker claimed - never a `jobs` row
-- at all for sending. All policy-matching (which alerts go to which
-- channels) already happened earlier, independently, inside the
-- "evaluator" role's own matching pass (see
-- shared/watchtower_worker_core/notification_policy_matcher.lua) - this poller only ever dispatches what's already queued, so it's identical
-- code on both worker runtimes (see shared/watchtower_worker_core/notification_senders.lua's own
-- header comment on why that module in particular is DB-free).
--
-- `deps` supplies the transport each worker runtime already has:
--   claim() -> {groups = [{channel, alerts, alert_ids}, ...]} | nil
--   send(channel, alerts) -> [{alert_id, ok, err}] | nil, err
--                                     (shared/watchtower_worker_core/notification_senders.lua,
--                                      identical call on both runtimes -
--                                      one result entry per alert sent)
--   report(channel_results) -> ok, err

local common = require("watchtower_worker_core.pollers.common")

local M = {}

-- Returns two values: (found, reported_ok) - see
-- shared/watchtower_worker_core/pollers/observe.lua's poll_and_run header comment for the
-- exact contract (here reported_ok is the final deps.report call's
-- success). Surfaced for shared/watchtower_worker_core/processors.lua's one-shot run_once
-- path; the persistent-loop caller ignores the 2nd value, unchanged.
function M.poll_and_run(deps, logger)
  local batch = common.claim("batch_notify_poller", deps, logger)
  if not batch then
    return false, true
  end

  local channel_results = {}

  for _, group in ipairs(batch.groups) do
    -- deps.send now sends one message per alert and returns an array of
    -- {alert_id, ok, err} (see shared/watchtower_worker_core/notification_senders.lua) - pcall
    -- still guards against the call itself raising before returning
    -- anything (e.g. a malformed channel config), in which case every
    -- alert in the group is recorded as failed with that error.
    local ok, results_or_err = pcall(deps.send, group.channel, group.alerts)
    if ok and type(results_or_err) == "table" then
      for _, r in ipairs(results_or_err) do
        table.insert(channel_results, {
          channel_id = group.channel.id,
          alert_id = r.alert_id,
          ok = r.ok and true or false,
          reason = (not r.ok) and tostring(r.err) or nil,
        })
      end
    else
      for _, alert_id in ipairs(group.alert_ids) do
        table.insert(channel_results, {
          channel_id = group.channel.id,
          alert_id = alert_id,
          ok = false,
          reason = tostring(results_or_err),
        })
      end
    end
  end

  local report_ok, report_err = deps.report(channel_results)
  common.check_report("batch_notify_poller", "deliveries", report_ok, report_err, logger)

  return true, report_ok
end

return M
