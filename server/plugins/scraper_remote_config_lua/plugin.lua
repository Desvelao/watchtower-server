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
local tableshape = require("tableshape").types
local tobool_from_key = require("lib.utils").tobool_from_key
local WebScraper = require('webscraper').WebScraper
local WebScraperFilters = require('webscraper.filters.filters')
local WebScraperValidators = require('webscraper.filters.validators')
local utils = require('plugins.scraper_remote_config_lua.utils')
local cjson = require('cjson')
local Logger = require('core.logger')

local schema = require("lapis.db.schema")

local base_path = "/api/scrapers/remote_config_lua"

local Plugin = {
  name = 'scraper_remote_config_lua',
  install_deps = {'lua-requests'}
}

local function noop() end

-- parser deep limit
htmlparser_looplimit=8000

-- Accepts either a dot-separated string path or a table of keys
local function getProperty(obj, path)
  local keys = {}

  -- Convert string path to table of keys
  if type(path) == "string" then
    for key in string.gmatch(path, "[^%.]+") do
      table.insert(keys, key)
    end
  elseif type(path) == "table" then
    keys = path
  else
    error("Path must be a string or a table")
  end

  -- Traverse the table recursively
  local function traverse(current, index)
    if index > #keys or type(current) ~= "table" then
      return current
    end
    return traverse(current[keys[index]], index + 1)
  end

  return traverse(obj, 1)
end

local validate_url = types.pattern("^https?://")

local validate_string_non_empty = tableshape.custom(function(val)
    if type(val) == 'string' and #val > 0 then
        return true
    else
        return nil, 'Should be a non-empty string'
    end
end)

local function get_props_from_table(data)
    return {
        urls_match=utils.format_text_array(data.urls_match),
        fields_price_selector=utils.format_text_array(data.fields.price.selector),
        fields_price_transform=getProperty(data, 'fields.price.transform'),
        fields_price_validate=getProperty(data, 'fields.price.validate'),
        fields_discount_selector=utils.format_text_array(data.fields.discount.selector),
        fields_discount_transform=getProperty(data, 'fields.discount.transform'),
        fields_discount_validate=getProperty(data, 'fields.discount.validate'),
        fields_available_selector=utils.format_text_array(data.fields.available.selector),
        fields_available_transform=getProperty(data, 'fields.available.transform'),
        fields_available_validate=getProperty(data, 'fields.available.validate'),
        urls_test=utils.format_text_array(data.urls_test),
    }
end

local validate_array_of_string_non_empty = tableshape.array_of(validate_string_non_empty)

function Plugin.setup(app)
    -- Endpoint: List all product scraping configurations
    app:get(base_path .. "/site", get_optional_query_parameters({
        {"from", tableshape.number, tonumber},
        {"size", tableshape.number, tonumber},
        {"enabled",tableshape.boolean, tobool_from_key},
        {"name",tableshape.string, nil},
        {"search",tableshape.string, nil},
        {"sort",tableshape.string, nil},
        {"id", tableshape.number, tonumber},
    })(function(self)
        self.context.logger:debug("Getting sites")
        -- Retrieve the list of products from the database
        local db_query = get_db_query_params_from_request_params(self, {"enabled", "name", "id"})
        local where_clause = get_db_where_clause_from_request_params(self, {"enabled", "name", "id"})

        self.context.logger:debug("DB query {db_query}", {db_query=db_query})
        self.context.logger:debug("WHERE clause {where_clause}", {where_clause=where_clause})

        local ok, result = pcall(function()
            self.context.logger:debug("Selecting items with {db_query} {where_clause}")
            local items = models.ScraperRemote:select(db_query)
            local total_items = models.ScraperRemote:count(where_clause)
            return {items=items, total_items=total_items}
        end)

        self.context.logger:debug("Selecting items with {db_query} {where_clause} results {ok}", {db_query=db_query, where_clause=where_clause, ok=ok})

        if not ok then
            local error_message = result or "Unable to get the products list."
            self.context.logger:error("Error {error}", {error = error_message})
            return { status = 500, json = { error = error_message} }
        end

        local items = result.items
        local total_items = result.total_items

        self.context.logger:debug("Selecting items with {db_query} {where_clause} results {ok} {total_items}", {db_query=db_query, where_clause=where_clause, ok=ok, total_items=total_items})

        return { json = {items = items or {}, total_items = total_items}}
    end))    


    app:post(base_path .. "/site", json_params(function(self)

        local item = get_props_from_table(self.params)
        item.name = self.params.name

        local new_item = models.ScraperRemote:create(item)
    
        return { status = 201, json = { success = true, message = "Product added successfully.", item=new_item } }
    end))

    app:post(base_path .. "/test", capture_bad_request_params_validate({
        {"name",validate_string_non_empty},
        {"test_url",validate_url},
        {"urls_match",validate_array_of_string_non_empty},
        {"fields", tableshape.shape{
            available=tableshape.shape{
                selector=validate_array_of_string_non_empty,
                transform=tableshape.string,
                validate=tableshape.string
            },
            discount=tableshape.shape{
                selector=validate_array_of_string_non_empty,
                transform=tableshape.string,
                validate=tableshape.string
            },
            price=tableshape.shape{
                selector=validate_array_of_string_non_empty,
                transform=tableshape.string,
                validate=tableshape.string
            }
        }},
        
    })(function(self)
        local webscraper = WebScraper:new();
        for k, v in pairs(WebScraperFilters) do
            webscraper.filters:register(k, v)
        end

        for k, v in pairs(WebScraperValidators) do
            webscraper.validators:register(k, v)
        end

        webscraper.sites:register(self.params.name, {
            name = self.params.name,
            urls_match = self.params.urls_match,
            fields = self.params.fields,
        })

        local data = webscraper:run(self.params.test_url, {}, {logger={info=print,debug=print, warn=print, error=print}})

        return {json = { ok = data and true or false, data = data or nil, test= self.params } }
    end))
    
    -- Endpoint: Edit a product for scraping (using code as identifier)
    app:put(base_path .. "/site/:id", capture_bad_request_params_validate({
        {"id",types.db_id},
        {"name",validate_string_non_empty},
        {"urls_match",validate_array_of_string_non_empty},
        {"fields", tableshape.shape{
            available=tableshape.shape{
                selector=validate_array_of_string_non_empty,
                transform=tableshape.string,
                validate=tableshape.string
            },
            discount=tableshape.shape{
                selector=validate_array_of_string_non_empty,
                transform=tableshape.string,
                validate=tableshape.string
            },
            price=tableshape.shape{
                selector=validate_array_of_string_non_empty,
                transform=tableshape.string,
                validate=tableshape.string
            }
        }},
        {"urls_test",validate_array_of_string_non_empty},
    })(function(self)
        local id = self.params.id

        local item = get_props_from_table(self.params)
        item.name = self.params.name
        item.updated_at=db.format_date()

        -- Update operation in the database
        local opr, err = models.ScraperRemote:find({
            id=id
        }):update(item)
    
        if not opr then
            return { status = 500, json = { error = err or "Unable to site product." } }
        end

        return { json = { success = true, message = "Site updated successfully." } }
    end))

    app:post(base_path .. "/site/:id/test", capture_bad_request_params_validate({
        {"id",types.db_id},
        {"test_url",validate_url},
    })(function(self)
        local id = self.params.id
        local test_url = self.params.test_url

        local opr, err = models.ScraperRemote:find({
            id=id
        })
        
        local webscraper = WebScraper:new();
        for k, v in pairs(WebScraperFilters) do
            webscraper.filters:register(k, v)
        end

        for k, v in pairs(WebScraperValidators) do
            webscraper.validators:register(k, v)
        end

        webscraper.sites:register(opr.name, {
            name = opr.name,
            urls_match = opr.urls_match,
            fields = opr.fields,
        })

        local data = webscraper:run(self.params.test_url, {}, {logger={info=print,debug=print, warn=print, error=print}})

        return {json = { ok = data and true or false, data = data or nil, test=self.params} }
    end))
    
    -- Endpoint: Remove a site for scraping (identified by id)
    app:delete(base_path .. "/site/:id", capture_bad_request_params_validate({
        {"id",types.db_id},
    })(function(self)
        local id = self.params.id

        local opr, err = models.ScraperRemote:find({
            id=id
        }):delete()
    
        if not opr then
            return { status = 500, json = { error = err or "Unable to remove site." } }
        end
    
        return { json = { success = true, message = "Site removed successfully." } }
    end))


    -- Endpoint: Export sites data
    app:get(base_path .. "/export", function(self)

        local ok, result = pcall(function()
            local items = models.ScraperRemote:select()
            local total_items = models.ScraperRemote:count()
            return {items=items, total_items=total_items}
        end)

        if not ok then
            return { status = 500, json = { error = result or "Unable to get the list." } }
        end
        local date_str = os.date("%Y-%m-%d")
        local filename = "export_scraper_remote_lua_" .. date_str .. ".json"
        return {
            status = 200,
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Disposition"] = 'attachment; filename="'.. filename..'"'
            },
            layout = false,
            json = {description='Sites configuration for scraper:remote', items=result.items or {}}
        }
    end)

    app:post(base_path .. "/import", function(self)

        local file = self.params.file

        if not file then
            return { status = 400, json = { error = "File is missing." } }
        end

        local ok, err = pcall(cjson.decode, file.content)

        if not ok then
            return { status = 500, json = { ok=ok, error = "File content could not be decoded" } }
        end

        local ok_import, err_import = pcall(function(items)

            local data = {}

            for i,v in ipairs(items) do

                local item = get_props_from_table(v)
                item.name = v.name

                local new_item = models.ScraperRemote:create(item)
                table.insert(data, new_item)
            end

            return data        
        end, err.items)

        if not ok_import then
            return { status = 500, json = { ok=ok_import, error = err_import or "There an unknown error saaving the data in the database." } }
        end

        return {json = { ok=ok_import, content=err }}
    end)

    app:post(base_path .. "/test/_all", capture_bad_request_params_validate({
        {"test_url",validate_url},
    })(function(self)

        local test_url = self.params.test_url

        local opr, err = models.ScraperRemote:select()
        
        local webscraper = WebScraper:new();
        for k, v in pairs(WebScraperFilters) do
            webscraper.filters:register(k, v)
        end

        for k, v in pairs(WebScraperValidators) do
            webscraper.validators:register(k, v)
        end

        for _, site in pairs(opr) do
            webscraper.sites:register(site.name, {
                name = site.name,
                urls_match = site.urls_match,
                fields = site.fields,
            })
        end

        local data = webscraper:run(self.params.test_url, {}, {logger={info=print,debug=print, warn=print, error=print}})

        return {json = { ok = data and true or false, data = data or nil, test=self.params} }
    end))
end

return Plugin