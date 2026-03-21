local db = require("lapis.db")
local json_params = require("lapis.application").json_params

local base_path = "/api/health"

local Plugin = {
  name = 'healthcheck'
}

function Plugin.setup(app)
    app:get(base_path.."/dbv", function()
        local status, result = pcall(db.query, "SELECT * as result") -- TODO: fix query to check the connection status
        
        if not status then
          return { status = 500, json = { message = "DB connection failed", error = result } }
        end
        return { json = { message = "DB connection OK", result = result } }
      end)
end

return Plugin