local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local models = require('models')
local capture_bad_request_params_validate = require("lib.routes").capture_bad_request_params_validate
local types = require("lapis.validate.types")
local tableshape = require("tableshape").types
local get_optional_query_parameters = require("lib.routes").get_optional_query_parameters
local get_db_query_params_from_request_params = require("lib.routes").get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = require("lib.routes").get_db_where_clause_from_request_params
local create_search_map_clause = require("lib.routes").create_search_map_clause

local base_path = "/api/notification_channels"

local Plugin = {
  name = 'notifications_channels'
}

function Plugin.setup(app)
    -- Endpoint: List all product scraping configurations
    app:get(base_path, get_optional_query_parameters({
        {"from", tableshape.number, tonumber},
        {"size", tableshape.number, tonumber},
        {"enabled",tableshape.boolean, tobool_from_key},
        {"name",tableshape.string, nil},
        {"search",tableshape.string, nil},
        {"sort",tableshape.string, nil},
        {"id", tableshape.number, tonumber},
    })(function(self)

        local where_params = {
                "enabled",
                "name",
                "id",
                {
                    key="search",
                    map_clause=create_search_map_clause({"name"})
                }
            }
        local db_query = get_db_query_params_from_request_params(
            self,
            where_params
        )
        local where_clause = get_db_where_clause_from_request_params(self, where_params)

        -- local db_query = get_db_query_params_from_request_params(self, {"enabled", "name", "id"})
        -- local where_clause = get_db_where_clause_from_request_params(self, {"name", "id"})

        local result = models.NotificationChannels:select(db_query)
        local total_items = models.NotificationChannels:count(where_clause)
        return { json = {items = result or {}, total_items=total_items} }
    end))
    
    -- Endpoint: List all product scraping configurations
    app:get(base_path .. "/:id", function(self)
        local id = self.params.id
        local item = models.NotificationChannels:find({id=id})
        if not item then
            return { status=404, json = { message = "Product was not found", id = id }}
        end
        return { json = {item = item} }
    end)
    
    -- Endpoint: Add a new product for scraping
    app:post(base_path, capture_bad_request_params_validate({
        {"type", types.valid_text},
        {"name", types.valid_text}
    })(function(self)
        -- TODO: validate types and options
        local data = {}
        for _, item in ipairs({"id","type","name"}) do
            local key, target_key
            if type(item) == 'string' then
                key = item
                target_key = item
            elseif type(item) == 'table' then
                key = item[1]
                target_key = item[2] or item[1]
            end
            data[target_key] = self.params[key]
        end
        data.options = self.params.options

        if not data.options then
            return { status = 400, json = { success = false, message = "Options are not defined for the notification channel." } }
        end

        local ok, result = pcall(function() return models.NotificationChannels:create(data) end)

        if not ok then
            return { status = 500, json = { success = false, message = result or "Unable to add notification channel." } }
        end
    
        return { status = 200, json = { success = true, message = "Notification channel added successfully.", data=result } }
    end))
    
    -- Endpoint: Edit a product for scraping (using code as identifier)
    app:put(base_path .. "/:id", capture_bad_request_params_validate({
        {"id", types.db_id},
        {"type", types.valid_text},
        {"name", types.valid_text}
    })(function(self)
        -- TODO: validate types and options
        local data = {}
        for _, item in ipairs({"id","type","name"}) do
            local key, target_key
            if type(item) == 'string' then
                key = item
                target_key = item
            elseif type(item) == 'table' then
                key = item[1]
                target_key = item[2] or item[1]
            end
            data[target_key] = self.params[key]
        end
        data.options = self.params.options

        if not data.options then
            return { status = 400, json = { success = false, message = "Options are not defined for the notification channel." } }
        end

        local ok, result = pcall(function() return models.NotificationChannels:update(data, data.id) end)

        if not ok then
            return { status = 500, json = { success = false, message = result or "Unable to update notification channel." } }
        end
    
        return { status = 200, json = { success = true, message = "Notification channel updateed successfully.", data=result } }
    end))
    
    app:delete(base_path .. "/:id", function(self)
        local id = self.params.id
    
        if not id then
            return { status = 400, json = { error = "Missing monitor id." } }
        end

        local opr, err = models.NotificationChannels:find({
            id=id
        }):delete()
    
        if not opr then
            return { status = 500, json = { error = err or "Unable to remove monitor." } }
        end
    
        return { json = { success = true, message = "Product monitor successfully.", data = err } }
    end)
end

return Plugin