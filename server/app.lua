local lapis = require("lapis")
local db = require("lapis.db")
local PluginSystem = require("lib.plugins-service")
local Logger = require("core.logger")
local app = lapis.Application()

-- The empty tables are treated as arrays
require("cjson").encode_empty_table_as_object(false)

app:before_filter(function(self)
    self.context = {
        logger = Logger:new(
            "DEBUG",
            function (level, message)
                return string.format("[%s] [%s %s] %s", level, self.req.method, self.req.parsed_url.path, message)
            end
        )
    }
end)

app:get("/", function()
    return "Welcome to Lapis " .. require("lapis.version")
end)

app:get("/api", function()
    return "Welcome to API"
end)

PluginSystem:new()
    :add_plugin(require('plugins.security.plugin'))
    :add_plugin(require('plugins.alerting.plugin'))
    :add_plugin(require('plugins.monitoring.plugin'))
    :add_plugin(require('plugins.notification_channels.plugin'))
    :add_plugin(require('plugins.items.plugin'))
    :add_plugin(require('plugins.scraper_remote_config_lua.plugin'))
    :run(app)

return app
