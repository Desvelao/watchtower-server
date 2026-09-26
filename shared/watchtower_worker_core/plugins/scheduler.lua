-- Built-in "scheduler" role plugin: registers the fire-due-tasks and
-- reap-stale-jobs tasks - the "scheduler" role's entire job. Reuses
-- processors.lua's existing do_fire_due_tasks/do_reap_stale_jobs bodies
-- unchanged (still called with the original (context, provider, utils)
-- shape they were written for - `context` doubles as the `ctx` they close
-- over, since it carries the same fields: config, plus whatever counters
-- they bump on it directly, e.g. context._jobs_fired_total below).
local has_role = require("watchtower_worker_core.roles").has_role
local processors = require("watchtower_worker_core.processors")
local phases = require("watchtower_worker_core.phases")

local Plugin = { name = "scheduler" }

function Plugin.setup(context)
  if not has_role(context.config.roles, "scheduler") then
    return nil
  end

  local utils = { logger = context.logger }
  local config = context.config

  return {
    -- phases.SCHEDULE: must run before observe/analyze/notify's own
    -- "queue" source mode, which claims the `jobs` rows fire_due_tasks
    -- queues here - see watchtower_worker_core.phases.
    tasks = {
      {
        name = "fire_due_tasks",
        role = "scheduler",
        phase = phases.SCHEDULE,
        interval = config.scheduler.interval,
        run_on_start = config.scheduler.run_on_start,
        run = function() return processors.do_fire_due_tasks(context, context.connector, utils) end,
      },
      {
        name = "reap_stale_jobs",
        role = "scheduler",
        phase = phases.SCHEDULE,
        interval = config.scheduler.reap_stale.interval,
        run_on_start = config.scheduler.run_on_start,
        run = function() return processors.do_reap_stale_jobs(context, context.connector, utils) end,
      },
    },
    heartbeat_properties = function()
      return { jobs_fired = context._jobs_fired_total or 0 }
    end,
  }
end

return Plugin
