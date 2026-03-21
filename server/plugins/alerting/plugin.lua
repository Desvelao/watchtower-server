local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local models = require('models')
local capture_bad_request_params_validate = require("lib.routes").capture_bad_request_params_validate
local types = require("lapis.validate.types")
local tableshape = require("tableshape").types
local get_optional_query_parameters = require("lib.routes").get_optional_query_parameters
local get_db_query_params_from_request_params = require("lib.routes").get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = require("lib.routes").get_db_where_clause_from_request_params
local tobool_from_key = require("lib.utils").tobool_from_key

local base_path = "/api/alerts"

local Plugin = {
  name = 'alerting'
}

function Plugin.setup(app)
    -- Endpoint: List all product scraping configurations
    app:get(base_path, get_optional_query_parameters({
        {"from", tableshape.number, tonumber},
        {"size", tableshape.number, tonumber},
        {"enabled",tableshape.boolean, tobool_from_key},
        {"item_id",tableshape.number, tonumber},
        {"name",tableshape.string, nil},
        {"id", tableshape.number, tonumber},
    })(function(self)
        local db_query = get_db_query_params_from_request_params(self, {"enabled", "name", "id", "item_id"})
        local where_clause = get_db_where_clause_from_request_params(self, {"enabled", "name", "id", "item_id"})
        local result = models.Alerts:select(db_query)
        local total_items = models.Alerts:count(where_clause)
        return { json = {items = result or {}, total_items=total_items} }
    end))
    
    -- Endpoint: List all product scraping configurations
    app:get(base_path .. "/:id", function(self)
        local id = self.params.id
        local item = models.Alerts:find({id=id})
        if not item then
            return { status=404, json = { message = "Product was not found", id = id }}
        end
        return { json = {item = item} }
    end)
    
    -- Endpoint: Add a new product for scraping
    app:post(base_path, capture_bad_request_params_validate({
        {"name", types.valid_text},
        {"enabled", tableshape.boolean},
        -- {"channels", tableshape.boolean}, -- TODO: add validation
        {"item_id", types.db_id},
        {"trigger_on_price", types.valid_text},
        {"trigger_on_discount", tableshape.boolean},
        {"trigger_on_available", tableshape.boolean},
    })(function(self)
        local data = {}
        for _, item in ipairs({"name", "channels", "item_id", "enabled", "trigger_on_price", "trigger_on_discount", "trigger_on_available"}) do
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

        local result = models.Alerts:create(data)

        return { status = 200, json = { success = true, message = "Alert added successfully.", data=result } }
    end))
    
    -- Endpoint: Edit a product for scraping (using code as identifier)
    app:put(base_path .. "/:id", capture_bad_request_params_validate({
        {"id", types.db_id},
        {"name", types.valid_text},
        {"enabled", tableshape.boolean},
        {"channels", tableshape.array_of(types.db_id)}, -- TODO: add validation
        {"item_id", types.db_id},
        {"trigger_on_price", types.valid_text},
        {"trigger_on_discount", tableshape.boolean},
        {"trigger_on_available", tableshape.boolean},
    })(function(self)
        -- TODO: validate types and options
        local data = {}
        for _, item in ipairs({"id","name", "enabled", "item_id", "trigger_on_price", "trigger_on_discount", "trigger_on_available", "channels"}) do
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

        local ok, result = pcall(function() return models.Alerts:update(data, data.id) end)

        if not ok then
            return { status = 500, json = { success = false, message = result or "Unable to update notification channel." } }
        end
    
        return { status = 200, json = { success = true, message = "Notification channel updateed successfully.", data=result } }
    end))
    
    app:delete(base_path .. "/:id", function(self)
        local id = self.params.id
    
        if not id then
            return { status = 400, json = { error = "Missing alert id." } }
        end

        local opr, err = models.Alerts:find({
            id=id
        }):delete()
    
        if not opr then
            return { status = 500, json = { error = err or "Unable to remove alert." } }
        end
    
        return { json = { success = true, message = "Alert removed successfully.", data = err } }
    end)
end

return Plugin