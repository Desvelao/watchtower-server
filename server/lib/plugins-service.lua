-- Plugin loader. Mirrors public/src/core/services/plugin-service.js (the
-- frontend twin, which is the correct reference implementation) - manifests
-- are an array of tables looked up by `.name`, `dependencies` is an array of
-- plugin names, and cycle detection is a real length check.
local PluginSystem = {}

function PluginSystem:new()
  local instance = {
    __plugins = {},
    __manifests = {},
  }
  return setmetatable(instance, { __index = PluginSystem })
end

function PluginSystem:add_plugin(plugin)
  table.insert(self.__manifests, plugin)
  return self
end

-- Kahn's algorithm over `manifest.dependencies` (an array of plugin names).
-- Returns an ordered array of plugin names.
local function resolve_order(manifests)
  local graph, in_degree, by_name = {}, {}, {}

  for _, m in ipairs(manifests) do
    graph[m.name] = {}
    in_degree[m.name] = 0
    by_name[m.name] = m
  end

  for _, m in ipairs(manifests) do
    for _, dep in ipairs(m.dependencies or {}) do
      if not by_name[dep] then
        error(("Plugin '%s' requires missing '%s'"):format(m.name, dep))
      end
      table.insert(graph[dep], m.name)
      in_degree[m.name] = in_degree[m.name] + 1
    end
  end

  local queue, order = {}, {}
  for name, deg in pairs(in_degree) do
    if deg == 0 then
      table.insert(queue, name)
    end
  end

  while #queue > 0 do
    local n = table.remove(queue, 1)
    table.insert(order, n)
    for _, m in ipairs(graph[n]) do
      in_degree[m] = in_degree[m] - 1
      if in_degree[m] == 0 then
        table.insert(queue, m)
      end
    end
  end

  if #order ~= #manifests then
    error("Cycle detected in plugin dependencies")
  end

  return order, by_name
end

function PluginSystem:discover()
  local order, by_name = resolve_order(self.__manifests)

  for _, name in ipairs(order) do
    table.insert(self.__plugins, by_name[name])
  end

  return self
end

-- Runs `method` on every plugin in dependency order, threading each
-- plugin's return value into the plugins that declare it as a dependency
-- (looked up by name, not array position). Returns the full results table
-- keyed by plugin name, so PluginSystem:run(app) can hand services between
-- plugins (e.g. the `security` plugin returns {auth, rbac, users, roles,
-- perms}, consumed by any plugin declaring dependencies = {'security'}).
function PluginSystem:run_by_plugin(method, app)
  local results = {}

  for _, plugin in ipairs(self.__plugins) do
    local plugin_deps = {}

    if plugin.dependencies then
      for _, dep in ipairs(plugin.dependencies) do
        plugin_deps[dep] = results[dep]
      end
    end

    if type(plugin[method]) == "function" then
      results[plugin.name] = plugin[method](app, plugin_deps)
    end
  end

  return results
end

function PluginSystem:run(app)
  self:discover()
  return self:run_by_plugin("setup", app)
end

return PluginSystem
