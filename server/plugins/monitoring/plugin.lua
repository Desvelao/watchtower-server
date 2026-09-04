local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local models = require('models')
local capture_bad_request_params_validate = require("lib.routes").capture_bad_request_params_validate
local get_db_query_params_from_request_params = require("lib.routes").get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = require("lib.routes").get_db_where_clause_from_request_params
local create_search_map_clause = require("lib.routes").create_search_map_clause
local compose = require("lib.routes").compose
local types = require("lapis.validate.types")
local tableshape = require("tableshape").types

-- Price observation ingest/history. Base path stays "/api/monitors" here -
-- renamed to "/api/observations" in the Phase 3 rename to
-- plugins/observations, which frees "monitors" for the scraping-agent
-- registry (Phase 4).
local base_path = "/api/monitors"

local Plugin = {
  name = 'monitoring',
  dependencies = {'security'},
}

function Plugin.setup(app, deps)
    local security = deps.security
    local auth, rbac, perms = security.auth, security.rbac, security.perms
    local require_auth = auth:with({require = true})

  -- Endpoint: List all product scraping configurations
    -- TODO: add filtering
    app:get(base_path, compose(require_auth, rbac:with(perms.OBSERVATIONS_READ))(function(self)
        -- Retrieve the list of products from the database
        local where_params = {
                "id",
                {
                    key="search",
                    map_clause=create_search_map_clause({"url"})
                }
            }
        local db_query = get_db_query_params_from_request_params(
            self,
            where_params
        )
        local where_clause = get_db_where_clause_from_request_params(self, where_params)

        -- local db_query = get_db_query_params_from_request_params(self, {"name", "id"})
        -- local where_clause = get_db_where_clause_from_request_params(self, {"name", "id"})

        local ok, result = pcall(function()
            local monitors = models.Monitors:select(db_query)
            models.Items:include_in(monitors, "item_id")
            local total_items = models.Monitors:count(where_clause)
            return {items=monitors, total_items=total_items}
        end)

        if not ok then
            return { status = 500, json = { error = result or "Unable to get the monitor list." } }
        end

        return { json = {items = result.items or {}, total_items = result.total_items} }
    end))

    -- Endpoint: List all product scraping configurations
    -- app:get(base_path .. "/:id", function(self)
    --     local id = self.params.id
    --     local item = models.Items:find({id=id})
    --     if not item then
    --         return { status=404, json = { message = "Product was not found", id = id }}
    --     end
    --     return { json = {item = item} }
    -- end)
    
    -- Endpoint: Add a new product for scraping
    app:post(base_path, compose(require_auth, rbac:with(perms.OBSERVATIONS_CREATE))(capture_bad_request_params_validate({
        {"id", types.db_id},
        {"price", tableshape.number},
        {"url", types.valid_text},
        {"timestamp", types.valid_text}
    })(function(self)
        local data = {}
        for _, item in ipairs({{"id", "item_id"},"price", "url", "timestamp", "available", "discount"}) do
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

        local ok, result = pcall(models.Monitors.create, models.Monitors, data)

        if not ok then
            return { status = 500, json = { success = false, message = result or "Unable to add record." } }
        end
    
        return { status = 200, json = { success = true, message = "Monitor record added successfully.", data=result } }
    end)))

    -- Endpoint: Edit a product for scraping (using code as identifier)
    -- app:put(base_path .. "/:id", json_params(function(self)
    --     local id = self.params.id
    --     local name = self.params.name
    --     local url = self.params.url
    
    --     if not id or not name or not url then
    --         return { status = 400, json = { error = "Missing product info." } }
    --     end

    --     -- Update operation in the database
    --     local opr, err = models.Items:find({
    --         id=id
    --     }):update({
    --         name=name,
    --         url=url
    --     })
    
    --     if not opr then
    --         return { status = 500, json = { error = err or "Unable to update product." } }
    --     end
    --     -- Manage errors
    --     -- local ok, result = pcall(function()
    --     --     db.query("UPDATE products SET url = ?, wanted_price = ? WHERE code = ?", url, wanted_price, code)
    --     -- end)
    
    --     -- if not ok then
    --     --     return { status = 500, json = { error = result or "Unable to update product." } }
    --     -- end
    --     -- return "test2"
    --     return { json = { success = true, message = "Product updated successfully." } }
    -- end))
    
    app:delete(base_path .. "/:id", compose(require_auth, rbac:with(perms.OBSERVATIONS_DELETE))(function(self)
        local id = self.params.id

        if not id then
            return { status = 400, json = { error = "Missing monitor id." } }
        end

        local opr, err = models.Monitors:find({
            id=id
        }):delete()

        if not opr then
            return { status = 500, json = { error = err or "Unable to remove monitor." } }
        end

        return { json = { success = true, message = "Product monitor successfully.", data = err } }
    end))
end

return Plugin