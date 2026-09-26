-- The five built-in role plugins, bundled as one array so a worker entry
-- point can do `local plugins = require("watchtower_worker_core.plugins")`
-- and append its own (e.g. watchtower_observer_web_scraper.plugin) before
-- handing the whole list to watchtower_worker_core.lifecycle.build. None of
-- these declare `dependencies` - they're independent of each other and of
-- any observer-type plugin, so their relative order here doesn't matter
-- (watchtower_worker_core.lifecycle topologically sorts by declared
-- dependencies, not registration order).
return {
  require("watchtower_worker_core.plugins.scheduler"),
  require("watchtower_worker_core.plugins.analyzer"),
  require("watchtower_worker_core.plugins.evaluator"),
  require("watchtower_worker_core.plugins.deliver"),
  require("watchtower_worker_core.plugins.observer"),
}
