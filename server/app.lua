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

-- Unauthenticated liveness check for container/orchestrator health probes.
-- Deliberately not wrapped in the security plugin's auth/rbac composition.
app:get("/api/health", function()
    ngx.update_time()
    local start_time = ngx.now()

    local db_ok = pcall(function() db.query("SELECT 1") end)

    ngx.update_time()
    local elapsed_ms = math.floor((ngx.now() - start_time) * 100000 + 0.5) / 100

    return {
        json = {
            status = db_ok and "ok" or "degraded",
            db = {
                status = db_ok and "ok" or "error",
                latency_ms = elapsed_ms,
            },
            latency_ms = elapsed_ms,
        },
    }
end)

PluginSystem:new()
    :add_plugin(require('plugins.security.plugin'))
    :add_plugin(require('plugins.rules.plugin'))
    :add_plugin(require('plugins.alerting.plugin'))
    :add_plugin(require('plugins.entities.plugin'))
    :add_plugin(require('plugins.workers.plugin'))
    :add_plugin(require('plugins.scheduler.plugin'))
    :add_plugin(require('plugins.jobs.plugin'))
    :add_plugin(require('plugins.notification_channels.plugin'))
    :add_plugin(require('plugins.observer_configs.plugin'))
    :run(app)

return app
