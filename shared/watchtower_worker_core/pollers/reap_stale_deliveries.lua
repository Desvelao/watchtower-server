-- Periodic housekeeping tick, run by a worker that declares the "evaluator"
-- role: asks the server to reset any `alert_deliveries` row stuck in
-- 'triggering' past `timeout_seconds` back to 'error' (see
-- server/plugins/notification_channels/services/delivery_queue.lua's
-- reap_stale) - a claim whose "deliver"-role worker crashed, hung, or lost
-- connectivity before reporting would otherwise sit in 'triggering' forever,
-- never sent and never retried. "evaluator" owns this the same way
-- "scheduler" owns jobs' own reap_stale (see pollers/reap_stale.lua) - it's
-- the role that *produces* this queue's rows, not the role that drains it.
--
-- Same shape as pollers/reap_stale.lua (a single injected function, no
-- claim/report split - the server does all the work in one call), given its
-- own dedicated module for the same reason: every worker-facing operation
-- gets one independently-requireable poller, used identically (modulo
-- transport) by both the embedded worker (calls the delivery_queue service
-- directly) and the standalone worker (PUT /api/alert_deliveries/reap-stale).
--
-- `deps` supplies the transport each worker runtime already has:
--   reap_stale_deliveries(timeout_seconds) -> {reaped = N, items = [...]}
local M = {}

-- Returns two values: (ok, reaped) - ok is false if reap_stale_deliveries
-- raised or returned `nil, err` (the standalone provider reports HTTP
-- failures that way rather than raising), true otherwise (with `reaped`
-- defaulting to 0 when the result didn't carry one). A reap event
-- (reaped > 0) is itself a signal something upstream hung, so it's logged
-- even on success - unlike most pollers here, which stay silent when
-- there's simply nothing to do.
function M.poll_and_run(deps, logger, timeout_seconds)
  local ok, result, err = pcall(deps.reap_stale_deliveries, timeout_seconds)
  if not ok or result == nil then
    logger.warn("reap_stale_deliveries_poller: reap_stale_deliveries failed: " .. tostring(ok and err or result))
    return false, 0
  end

  local reaped = (result and result.reaped) or 0
  if reaped > 0 then
    logger.warn("reap_stale_deliveries_poller: reaped " .. reaped .. " stale triggering alert_deliveries row(s)")
  end
  return true, reaped
end

return M
