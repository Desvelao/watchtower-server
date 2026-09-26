--- Logger class with debug, warn, error, and info levels
-- Supports rendering date and custom tags. Messages below the configured
-- level are dropped: Logger.new's `level` param (debug|info|warn|error,
-- case-insensitive) sets it, defaulting to "info" - debug output includes
-- every HTTP request and response body the worker makes, which can carry
-- secrets (channel configs with webhook URLs), so it's strictly opt-in.
-- This module never reads the environment itself (this is a
-- publishable library, shared/watchtower_worker_core, not tied to any one
-- consumer's config source) - each worker entry point
-- (worker/lua/main.lua/server/workers/observe_pending_worker.lua) resolves
-- its own LOG_LEVEL (from os.getenv or however else it sources config) and
-- passes the result in, typically via watchtower_worker_core.runner's own
-- `config.log_level` (see that module's build_config).
local Logger = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

local function resolve_level(level)
	local name = (level or ""):lower()
	return LEVELS[name] or LEVELS.info
end

---Formats a message with timestamp and tag
---@param level string Log level (DEBUG, INFO, WARN, ERROR)
---@param tag string Tag to identify the logger source
---@param message string The message to log
---@return string Formatted log message
local function format_message(level, tag, message)
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	return string.format("[%s] [%s] [%s] %s", timestamp, level, tag, message)
end

---Creates a new logger instance
---@param tag string Optional tag to identify the logger source
---@param level string Optional level threshold (debug|info|warn|error, case-insensitive); defaults to "info"
---@return table Logger instance with log level functions
function Logger.new(tag, level)
	tag = tag or "Logger"

	local threshold = resolve_level(level)
	local instance = {}

	local function emit(level_name, message)
		if LEVELS[level_name:lower()] >= threshold then
			print(format_message(level_name, tag, message))
		end
	end

	---Logs a debug level message
	function instance.debug(message)
		emit("DEBUG", message)
	end

	---Logs an info level message
	function instance.info(message)
		emit("INFO", message)
	end

	---Logs a warn level message
	function instance.warn(message)
		emit("WARN", message)
	end

	---Logs an error level message
	function instance.error(message)
		emit("ERROR", message)
	end

	return instance
end

return Logger
