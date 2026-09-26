-- Resolves config.plugins (an array of Lua module path strings, e.g.
-- "watchtower_observer_web_scraper.plugin" or a third-party observer-type/task
-- plugin module) into the actual plugin tables watchtower_worker_core.lifecycle
-- expects, so worker/lua/main.lua and server/workers/observe_pending_worker.lua
-- don't each duplicate the same require-loop.
--
-- A module not already part of this repo/image is resolved exactly like any
-- other require() - it just needs to be somewhere on LUA_PATH, e.g. a mounted
-- worker_plugins/ volume (see dev/docker-compose.yml) - no code change needed
-- at either entry point to pick it up, only a config.plugins entry naming it.
local M = {}

-- module_paths: config.plugins (may be nil/empty - both worker entry points
-- always work, they just get the five built-in role plugins and nothing
-- else). logger: optional {warn(message)}; defaults to a plain
-- watchtower_worker_core.logger instance so a call site with no logger of its
-- own yet (e.g. worker/lua/main.lua, this early in boot) still gets a
-- sensible fallback.
--
-- Returns the array of successfully require()d plugin tables, in
-- module_paths order, ready to table.insert-append onto
-- watchtower_worker_core.plugins' built-ins. A path that fails to require
-- (missing/broken module - e.g. a configured plugin whose code isn't
-- actually mounted) is logged and skipped rather than crashing worker boot,
-- mirroring watchtower_worker_core.lifecycle.build's own
-- pcall-plugin-setup/degrade-gracefully convention.
function M.require_configured(module_paths, logger)
  logger = logger or require("watchtower_worker_core.logger").new("plugin-loader")
  local plugins = {}
  for _, module_path in ipairs(module_paths or {}) do
    local ok, plugin_or_err = pcall(require, module_path)
    if ok then
      table.insert(plugins, plugin_or_err)
    else
      logger.warn(string.format(
        "plugin_loader: failed to require configured plugin '%s': %s",
        module_path, tostring(plugin_or_err)
      ))
    end
  end
  return plugins
end

return M
