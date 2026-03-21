local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local models = require('models')
local with_params = require("lapis.validate").with_params
local capture_errors_json = require("lapis.application").capture_errors_json
local capture_errors = require("lapis.application").capture_errors
local types = require("lapis.validate.types")
local capture_bad_request_params_validate = require("lib.routes").capture_bad_request_params_validate
local get_optional_query_parameters = require("lib.routes").get_optional_query_parameters
local get_db_query_params_from_request_params = require("lib.routes").get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = require("lib.routes").get_db_where_clause_from_request_params
local create_search_map_clause = require("lib.routes").create_search_map_clause
local tableshape = require("tableshape").types
local tobool_from_key = require("lib.utils").tobool_from_key
local cjson = require("cjson")

local base_path = "/api/items"

local Plugin = {
  name = 'items'
}

function Plugin.setup(app)
    -- Endpoint: List all item scraping configurations
    local handler_get = get_optional_query_parameters({
        {"from", tableshape.number, tonumber},
        {"size", tableshape.number, tonumber},
        {"enabled",tableshape.boolean, tobool_from_key},
        {"name",tableshape.string, nil},
        {"search",tableshape.string, nil},
        {"sort",tableshape.string, nil},
        {"id", tableshape.number, tonumber},
    })(function(self)
        -- Retrieve the list of items from the database
        local where_params = {
                "enabled",
                "name",
                "id",
                {
                    key="search",
                    map_clause=create_search_map_clause({"name", "url"})
                }
            }
        local db_query = get_db_query_params_from_request_params(
            self,
            where_params
        )
        local where_clause = get_db_where_clause_from_request_params(self, where_params)


        local ok, result = pcall(function()
            local items = models.Items:select(db_query)
            local total_items = models.Items:count(where_clause)
            return {items=items, total_items=total_items}
        end)


        if not ok then
            local err = result or "Unable to get the items list."
            return { status = 500, json = { error = err } }
        end

        return { json = {items = result.items or {}, total_items=result.total_items} }
    end)
    -- app:get(base_path, handler_get)
    
    
    -- Endpoint: List all item scraping configurations
    app:get(base_path .. "/:id", function(self)
        local id = self.params.id
        local item = models.Items:find({id=id})
        if not item then
            return { status=404, json = { message = "Item was not found", id = id }}
        end
        return { json = {item = item} }
    end)
    
    -- Reuse the previous slugify_url_path function
    function slugify_url_path(url)
        local path = url:match("https?://[^/]+(/.*)") or "/"
        path = path:gsub("%?.*$", ""):gsub("#.*$", "")
        local last_segment = path:match(".*/([^/]+)$") or path
        local slug = last_segment:lower()
        slug = slug:gsub("[^a-z0-9]+", "-")
        slug = slug:gsub("^-+", ""):gsub("-+$", "")
        if slug == "" then slug = "untitled" end
        return slug
    end

    -- New function: combine domain + slug
    function domain_plus_slug(url)
        -- Extract domain
        local domain = url:match("https?://([^/]+)") or "unknown-domain"
        
        -- Get slug from path
        local slug = slugify_url_path(url)
        
        -- Combine them
        return domain .. "-" .. slug
    end


    -- Endpoint: Add a new item for scraping
    local handler_post = capture_bad_request_params_validate({
            {"name",types.empty + types.valid_text},
            {"url",types.valid_text},
            {"enabled",tableshape.boolean},
        })(function(self, params)
            local name = params.name or domain_plus_slug(params.url)
            local url = params.url
            local enabled = self.params.enabled

            local new_item = models.Items:create({
                name=name,
                url=url,
                enabled=enabled
            })
        
            return { status = 201, headers = headers, json = { success = true, message = "Item added successfully.", item=new_item } }
        end)
    -- app:post(base_path, handler_post)

    app:match(base_path, function(self)
        if self.req.method == "OPTIONS" then
            -- Manage OPTIONS for CORS requests
            -- Enable CORS to allow defining items from external origin
            -- local headers = {}
            -- headers["Access-Control-Allow-Origin"] = "*"
            -- headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            -- headers["Access-Control-Allow-Headers"] = "content-type, authorization"
            return ""
        elseif self.req.method == "POST" then
            return handler_post(self)
        elseif self.req.method == "GET" then
            return handler_get(self)
        end
    end)
    
    -- Endpoint: Edit a item for scraping (using code as identifier)
    app:put(base_path .. "/:id", capture_bad_request_params_validate({
        {"id",types.db_id},
        {"name",types.valid_text},
        {"url",types.valid_text},
        {"enabled",tableshape.boolean},
    })(function(self)
        local id = self.params.id
        local name = self.params.name
        local url = self.params.url
        local enabled = self.params.enabled

        -- Update operation in the database
        local opr, err = models.Items:find({
            id=id
        }):update({
            name=name,
            url=url,
            enabled=enabled,
            updated_at=db.format_date(),
        })
    
        if not opr then
            return { status = 500, json = { error = err or "Unable to update item." } }
        end

        return { json = { success = true, message = "Item updated successfully." } }
    end))
    
    -- Endpoint: Remove a item for scraping (identified by id)
    app:delete(base_path .. "/:id", function(self)
        local id = self.params.id
    
        if not id then
            return { status = 400, json = { error = "Missing item id." } }
        end

        local opr, err = models.Items:find({
            id=id
        }):delete()
    
        if not opr then
            return { status = 500, json = { error = err or "Unable to remove item." } }
        end
    
        return { json = { success = true, message = "Item removed successfully." } }
    end)

    -- Endpoint: Export sites data
    app:get(base_path .. "/export", function(self)

        local ok, result = pcall(function()
            local items = models.Items:select()
            local total_items = models.Items:count()
            return {items=items}
        end)

        if not ok then
            return { status = 500, json = { error = result or "Unable to get the list." } }
        end
        local date_str = os.date("%Y-%m-%d")
        local filename = "export_items_" .. date_str .. ".json"
        return {
            status = 200,
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Disposition"] = 'attachment; filename="'.. filename..'"'
            },
            layout = false,
            json = {description='Items configuration', items=result.items or {}}
        }
    end)

    app:post(base_path .. "/import", function(self)

        local file = self.params.file

        if not file then
            return { status = 400, json = { error = result or "File is missing." } }
        end

        local ok, err = pcall(cjson.decode, file.content)

        if not ok then
            return { status = 500, json = { ok=ok, error = result or "File content could not be decoded" } }
        end

        local ok_import, err_import = pcall(function(items)

            local data = {}

            for i,v in ipairs(items) do
                local item = v;
                local new_item = models.Items:create({
                    name=item.name,
                    url=item.url,
                    enabled=item.enabled
                })
                table.insert(data, new_item)
            end

            return data        
        end, err.items)

        if not ok_import then
            return { status = 500, json = { ok=ok_import, error = err_import or "There an unknown error saaving the data in the database." } }
        end

        return {json = { ok=ok_import, content=err }}
    end)
end

return Plugin