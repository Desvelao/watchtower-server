export class PluginSystem {
  constructor() {
    this._plugins = [];
    this._manifests = [];
  }

  addPlugin(plugin) {
    this._manifests.push(plugin);
    return this;
  }

  run(core) {
    this.discover();
    this.runByPlugin('setup', core);
  }

  discover() {
    const order = this.resolveOrder(this._manifests);

    for (const name of order) {
      const manifest = this._manifests.find(p => p.name === name);
      if (!manifest) throw new Error(`Manifest for plugin '${name}' missing`);
      this._plugins.push(manifest);
    }

    return this;
  }

  runByPlugin(method, core) {
    const results = {};

    for (const plugin of this._plugins) {
      let pluginDeps = {};

      if (plugin.dependencies && plugin.dependencies.length > 0) {
        for (const dep of plugin.dependencies) {
          pluginDeps[dep] = results[dep];
        }
      }

      if (typeof plugin[method] === 'function') {
        results[plugin.name] = plugin[method](core, pluginDeps);
      }
    }
  }

  resolveOrder(manifests) {
    const graph = {};
    const inDegree = {};

    // Initialize graph
    for (const { name } of manifests) {
      graph[name] = [];
      inDegree[name] = 0;
    }

    // Build edges
    for (const { name, dependencies = [] } of manifests) {
      for (const dep of dependencies) {
        const depExists = manifests.find(p => p.name === dep);
        if (!depExists)
          throw new Error(`Plugin '${name}' requires missing '${dep}'`);
        graph[dep].push(name);
        inDegree[name]++;
      }
    }

    // Kahn's algorithm
    const queue = [];
    const order = [];

    for (const name in inDegree) {
      if (inDegree[name] === 0) queue.push(name);
    }

    while (queue.length > 0) {
      const n = queue.shift();
      order.push(n);

      for (const m of graph[n]) {
        inDegree[m]--;
        if (inDegree[m] === 0) queue.push(m);
      }
    }

    if (order.length !== manifests.length) {
      throw new Error('Cycle detected in plugin dependencies');
    }

    return order;
  }
}
