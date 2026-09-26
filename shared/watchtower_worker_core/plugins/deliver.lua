-- Built-in "deliver" role plugin: registers the alert_deliveries-queue
-- drain task (context.config.deliver.source picks "deliveries" - claims
-- directly off the queue, the default - vs "queue" - claims a
-- scheduler-fired type='deliver' job instead - both handled inside
-- do_run_pending_notify_batch itself, unchanged, so this plugin doesn't
-- need its own source branch the way analyzer/evaluator
-- do).
local has_role = require("watchtower_worker_core.roles").has_role
local processors = require("watchtower_worker_core.processors")
local phases = require("watchtower_worker_core.phases")

local Plugin = { name = "deliver" }

function Plugin.setup(context)
  if not has_role(context.config.roles, "deliver") then
    return nil
  end

  local utils = { logger = context.logger }
  local config = context.config

  return {
    -- phases.DELIVER: must run after evaluate (which enqueues the
    -- delivery this drains/sends) - see watchtower_worker_core.phases.
    tasks = {
      {
        name = "notify_batch",
        role = "deliver",
        phase = phases.DELIVER,
        interval = config.deliver.interval,
        run_on_start = config.deliver.run_on_start,
        run = function() return processors.do_run_pending_notify_batch(context, context.connector, utils) end,
      },
    },
    heartbeat_properties = function()
      return { deliveries_sent = context._deliveries_sent_total or 0 }
    end,
  }
end

return Plugin
