-- Logger class definition
local Logger = {}
Logger.__index = Logger

-- Constructor
function Logger:new(logLevel, formatter)
    local instance = {
        level = logLevel or "INFO",
        levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 },
        formatter = formatter or function(level, msg)
            return string.format("[%s] %s", level, msg)
        end
    }
    setmetatable(instance, Logger)
    return instance
end

-- Internal method to check if message should be logged
function Logger:shouldLog(messageLevel)
    return self.levels[messageLevel] >= self.levels[self.level]
end

-- Interpolation function: replaces {key} with values[key]
function Logger:interpolate(msg, values)
    return (msg:gsub("{(.-)}", function(key)
        return tostring(values[key] or "{" .. key .. "}")
    end))
end

-- Internal method to format and print the message
function Logger:log(level, msg, values)
    if self:shouldLog(level) then
        local interpolated = values and self:interpolate(msg, values) or msg
        print(self.formatter(level, interpolated))
    end
end

-- Logging methods
function Logger:debug(msg, values) self:log("DEBUG", msg, values) end
function Logger:info(msg, values)  self:log("INFO", msg, values)  end
function Logger:warn(msg, values)  self:log("WARN", msg, values)  end
function Logger:error(msg, values) self:log("ERROR", msg, values) end

-- Example usage with custom formatter
local customFormatter = function(level, msg)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    return string.format("%s | %s | %s", timestamp, level, msg)
end

return Logger

-- local logger = Logger:new("DEBUG", customFormatter)
-- logger:debug("Debugging the system")
-- logger:info("System is running")
-- logger:warn("Low disk space")
-- logger:error("System crash")
