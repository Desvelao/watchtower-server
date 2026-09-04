-- Concrete file-based backend for config_provider.lua, mirroring
-- src/server/application/services/config.lua's exact convention: a `.lua`
-- file loaded with loadfile()+pcall, whose returned table becomes the
-- config wholesale. Missing path / missing file / load error all yield an
-- empty table rather than raising - callers must tolerate "nothing
-- configured" rather than crash on it.

local Logger = require("logger")

local M = {}

function M.new(path)
  local instance = {
    logger = Logger.new("config_provider_file"),
    path = path,
  }

  return setmetatable(instance, { __index = M })
end

function M:load()
  if not self.path then
    return {}
  end

  local f = io.open(self.path, "r")
  if not f then
    self.logger.warn(string.format("config file not found: %s", self.path))
    return {}
  end
  f:close()

  local chunk, chunk_err = loadfile(self.path)
  if not chunk then
    self.logger.error(
      string.format(
        "failed to parse config file %s: %s",
        self.path,
        tostring(chunk_err)
      )
    )
    return {}
  end

  local ok, result = pcall(chunk)
  if not ok then
    self.logger.error(
      string.format(
        "failed to load config file %s: %s",
        self.path,
        tostring(result)
      )
    )
    return {}
  end

  if type(result) ~= "table" then
    self.logger.error(
      string.format("config file %s did not return a table", self.path)
    )
    return {}
  end

  self.logger.info(string.format("loaded config file %s", self.path))
  return result
end

return M
