-- Built-in "evaluator" role plugin: registers two tasks.
--
-- The main one is picked by context.config.evaluator.source
-- ("queue"/"interval", mirroring the analyzer plugin's own split exactly),
-- reusing do_run_pending_evaluate_batch/do_run_interval_evaluate_notify
-- unchanged. This role's claim only hands out a notify task's policy
-- scope/every enabled policy - the actual matching+enqueueing onto
-- alert_deliveries happens inside those do_* functions via
-- context.connector:evaluate_notify_policies. Sending is the fully separate
-- "deliver" role plugin's job.
--
-- The second, "reap_stale_deliveries", is this role's counterpart to the
-- "scheduler" plugin's own "reap_stale_jobs" task: evaluator is the role
-- that *produces* alert_deliveries rows (via the enqueue pass above), the
-- same relationship scheduler has to the jobs it fires - so it's also the
-- one that reaps a row a crashed/hung "deliver" worker left stuck in
-- 'triggering' (see do_reap_stale_deliveries's own header comment).
local has_role = require("watchtower_worker_core.roles").has_role
local processors = require("watchtower_worker_core.processors")
local phases = require("watchtower_worker_core.phases")

local Plugin = { name = "evaluator" }

function Plugin.setup(context)
  if not has_role(context.config.roles, "evaluator") then
    return nil
  end

  local utils = { logger = context.logger }
  local config = context.config

  local name, run
  if config.evaluator.source == "interval" then
    name = "evaluate_interval"
    run = function() return processors.do_run_interval_evaluate_notify(context, context.connector, utils) end
  else
    name = "evaluate_batch"
    run = function() return processors.do_run_pending_evaluate_batch(context, context.connector, utils) end
  end

  return {
    -- phases.EVALUATE: must run after analyze (which produces the alert
    -- this matches against notification_policies) and before deliver
    -- (which needs the delivery this enqueues) - see
    -- watchtower_worker_core.phases.
    tasks = {
      {
        name = name,
        role = "evaluator",
        phase = phases.EVALUATE,
        interval = config.evaluator.interval,
        run_on_start = config.evaluator.run_on_start,
        run = run,
      },
      {
        name = "reap_stale_deliveries",
        role = "evaluator",
        phase = phases.EVALUATE,
        interval = config.evaluator.reap_stale.interval,
        run_on_start = config.evaluator.run_on_start,
        run = function() return processors.do_reap_stale_deliveries(context, context.connector, utils) end,
      },
    },
    heartbeat_properties = function()
      return { deliveries_enqueued = context._deliveries_enqueued_total or 0 }
    end,
  }
end

return Plugin
