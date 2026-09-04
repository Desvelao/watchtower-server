-- Abstraction layer over where a `.lua` config table comes from - a
-- generic loader, not tied to any particular caller's config shape.
-- Callers only ever talk to this facade's :get()/:reload(), never to a
-- concrete backend directly - today the only backend is `opts.source =
-- "file"` (config_provider_file.lua, loadfile'd from a path the caller
-- supplies), but a future remote backend (e.g. a management API) can be
-- added as another `opts.source` value without touching any caller.

local M = {}

local BACKENDS = {
  file = function(opts)
    return require("config_provider_file").new(opts.path)
  end,
}

function M.new(opts)
  opts = opts or {}
  local source = opts.source or "file"
  local backend_factory = BACKENDS[source]
  if not backend_factory then
    error(
      string.format("config_provider: unknown source '%s'", tostring(source))
    )
  end

  local instance = {
    backend = backend_factory(opts),
    cache = nil,
  }

  return setmetatable(instance, { __index = M })
end

function M:get()
  if self.cache == nil then
    self.cache = self.backend:load()
  end
  return self.cache
end

function M:reload()
  self.cache = self.backend:load()
  return self.cache
end

return M
