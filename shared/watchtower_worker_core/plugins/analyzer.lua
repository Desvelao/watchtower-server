-- Built-in "analyzer" role plugin: registers one task, picked by
-- context.config.analyzer.source ("queue" - claims a scheduler-fired
-- type='analyze' job, the default; "interval" - a periodic full sweep, no
-- scheduler_tasks/jobs row involved), mirroring what used to be
-- processors.lua's SOURCE_TASKS "analyzer" entry. Reuses
-- do_run_pending_analyze_batch/do_run_interval_analyze_all unchanged.
local has_role = require("watchtower_worker_core.roles").has_role
local processors = require("watchtower_worker_core.processors")
local phases = require("watchtower_worker_core.phases")

local Plugin = { name = "analyzer" }

function Plugin.setup(context)
  if not has_role(context.config.roles, "analyzer") then
    return nil
  end

  local utils = { logger = context.logger }
  local config = context.config

  local name, run
  if config.analyzer.source == "interval" then
    name = "analyze_interval"
    run = function() return processors.do_run_interval_analyze_all(context, context.connector, utils) end
  else
    name = "analyze_batch"
    run = function() return processors.do_run_pending_analyze_batch(context, context.connector, utils) end
  end

  return {
    -- phases.ANALYZE: must run after observe (which produces the
    -- observation this re-runs rule matching against) and before evaluate
    -- (which needs the alert this may create) - see
    -- watchtower_worker_core.phases.
    tasks = {
      { name = name, role = "analyzer", phase = phases.ANALYZE, interval = config.analyzer.interval, run_on_start = config.analyzer.run_on_start, run = run },
    },
  }
end

return Plugin
