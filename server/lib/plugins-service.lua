-- Topological sort with cycle detection
local function resolve_order(manifests)
  local graph, in_degree = {}, {}
  -- Initialize nodes
  for name, m in pairs(manifests) do
    graph[name]     = {}
    in_degree[name] = 0
  end
  -- Build edges
  for name, m in pairs(manifests) do
    for dep,_ in pairs(m.dependencies or {}) do
      if not manifests[dep] then
        error(("Plugin '%s' requires missing '%s'"):format(name, dep))
      end
      table.insert(graph[dep], name)
      in_degree[name] = in_degree[name] + 1
    end
  end
  -- Kahn’s algorithm
  local queue, order = {}, {}
  for name, deg in pairs(in_degree) do
    if deg == 0 then table.insert(queue, name) end
  end
  while #queue > 0 do
    local n = table.remove(queue, 1)
    table.insert(order, n)
    for _, m in ipairs(graph[n]) do
      in_degree[m] = in_degree[m] - 1
      if in_degree[m] == 0 then table.insert(queue, m) end
    end
  end
  if #order ~= (#order + 0) then
    error("Cycle detected in plugin dependencies")
  end
  return order
end


local PluginSystem = {}

function PluginSystem:new()

  local instance = {
    __plugins = {},
    __manifests = {}
  }
  return setmetatable(instance, {__index=PluginSystem})
end

function PluginSystem:add_plugin(plugin)
  table.insert(self.__manifests, plugin)
  return self
end

function PluginSystem:run(app)

  -- Discover
  self:discover()

  -- Setup
  self:run_by_plugin('setup', app)

end

function PluginSystem:discover()
  local order = resolve_order(self.__manifests)
  for _, name in ipairs(order) do
    local manifest = self.__manifests[name]
    -- local ok, plugin = pcall(require, ("plugins.%s.plugin"):format(name))
    -- if not ok or type(plugin) ~= "table" then
    --   error(("Failed to load plugin '%s'"):format(name))
    -- end
    -- plugin.__meta = manifest
    local plugin = manifest
    table.insert(self.__plugins, plugin)
  end

  return self  
end

function PluginSystem:run_by_plugin(method, app)
  local deps={}
  for k,plugin in pairs(self.__plugins) do
    local plugin_deps = {};
    if plugin.dependencies then
      for k,v in ipairs(plugin.dependencies) do
        plugin_deps[v] = deps[v] 
      end
    end
    deps[plugin.name] = plugin[method](app, plugin_deps)
  end
end


return PluginSystem