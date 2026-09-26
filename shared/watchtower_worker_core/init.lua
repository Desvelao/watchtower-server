-- Public entry point for the `watchtower-worker-core` LuaRocks package -
-- see README.md in this directory. Requiring the individual submodules
-- directly (`require("watchtower_worker_core.runner")`,
-- `require("watchtower_worker_core.observer_registry")`,
-- `require("watchtower_worker_core.pollers.observe")`, etc) works
-- identically and is what watchtower-server's own worker entry points do;
-- `require("watchtower_worker_core")` is just a convenience for external
-- consumers that want the whole package behind one require.
return {
  logger = require("watchtower_worker_core.logger"),
  config_provider = require("watchtower_worker_core.config_provider"),
  config_provider_file = require("watchtower_worker_core.config_provider_file"),
  runner = require("watchtower_worker_core.runner"),
  loop = require("watchtower_worker_core.loop"),
  processors = require("watchtower_worker_core.processors"),
  observer_registry = require("watchtower_worker_core.observer_registry"),
  observable_type_cache = require("watchtower_worker_core.observable_type_cache"),
  cron = require("watchtower_worker_core.cron"),
  notification_senders = require("watchtower_worker_core.notification_senders"),
  worker_rule_matcher = require("watchtower_worker_core.worker_rule_matcher"),
  notification_policy_matcher = require("watchtower_worker_core.notification_policy_matcher"),
  config_report = require("watchtower_worker_core.config_report"),
  pollers = {
    observe = require("watchtower_worker_core.pollers.observe"),
    analyze = require("watchtower_worker_core.pollers.analyze"),
    evaluate = require("watchtower_worker_core.pollers.evaluate"),
    notify = require("watchtower_worker_core.pollers.notify"),
    scheduler = require("watchtower_worker_core.pollers.scheduler"),
    reap_stale = require("watchtower_worker_core.pollers.reap_stale"),
  },
}
