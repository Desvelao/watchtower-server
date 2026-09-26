-- Built-in "observer" role plugin: registers the generic observe-dispatch
-- task, picked by context.config.observer.source ("queue"/"interval",
-- mirroring the analyzer plugin's own split). Not named alongside
-- scheduler/analyzer/evaluator/deliver, but the same
-- kind of thing - bundled as a built-in core plugin for the same reason: it
-- doesn't depend on which observer *types* are registered (that's
-- context.observer_registry's job, built by watchtower_worker_core.lifecycle
-- once every plugin's setup has run - see its own header comment), it's the
-- fixed "drain whatever's pending, dispatch via observer_registry" behavior
-- every worker needs regardless of which observer-type plugins are loaded.
-- Reuses do_run_pending_observe_batch/do_run_interval_observe unchanged.
local has_role = require("watchtower_worker_core.roles").has_role
local processors = require("watchtower_worker_core.processors")
local phases = require("watchtower_worker_core.phases")

local Plugin = { name = "observer" }

function Plugin.setup(context)
  if not has_role(context.config.roles, "observer") then
    return nil
  end
  -- Explicit, symmetric off-switch for just this task, on top of the role
  -- check above - see config.observer.test_poll's own header comment in
  -- watchtower_worker_core.runner for why the two are separate flags.
  if context.config.observer.observe and context.config.observer.observe.enabled == false then
    return nil
  end

  local utils = { logger = context.logger }
  local config = context.config

  local name, run
  if config.observer.source == "interval" then
    name = "observe_interval"
    run = function() return processors.do_run_interval_observe(context, context.connector, utils) end
  else
    name = "observe_batch"
    run = function() return processors.do_run_pending_observe_batch(context, context.connector, utils) end
  end

  return {
    -- phases.OBSERVE: must run before analyze/evaluate, whose "interval"
    -- source mode re-processes whatever this task just posted/left pending
    -- - see watchtower_worker_core.phases.
    tasks = {
      { name = name, role = "observer", phase = phases.OBSERVE, interval = config.observer.interval, run_on_start = config.observer.run_on_start, run = run },
    },
  }
end

return Plugin
