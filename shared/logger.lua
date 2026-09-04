--- Logger class with debug, warn, error, and info levels
-- Supports rendering date and custom tags
local Logger = {}

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
---@return table Logger instance with log level functions
function Logger.new(tag)
	tag = tag or "Logger"

	local instance = {}

	---Logs a debug level message
	function instance.debug(message)
		local formatted = format_message("DEBUG", tag, message)
		print(formatted)
	end

	---Logs an info level message
	function instance.info(message)
		local formatted = format_message("INFO", tag, message)
		print(formatted)
	end

	---Logs a warn level message
	function instance.warn(message)
		local formatted = format_message("WARN", tag, message)
		print(formatted)
	end

	---Logs an error level message
	function instance.error(message)
		local formatted = format_message("ERROR", tag, message)
		print(formatted)
	end

	return instance
end

return Logger
