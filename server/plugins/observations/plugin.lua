local db = require("lapis.db")
local models = require('models')
local capture_bad_request_params_validate = require("lib.routes").capture_bad_request_params_validate
local get_db_query_params_from_request_params = require("lib.routes").get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = require("lib.routes").get_db_where_clause_from_request_params
local create_search_map_clause = require("lib.routes").create_search_map_clause
local compose = require("lib.routes").compose
local types = require("lapis.validate.types")
local tableshape = require("tableshape").types
local cjson = require("cjson")
local Logger = require("core.logger")

local logger = Logger:new("ERROR", function(level, message)
    return string.format("[%s] %s", level, message)
end)

-- Price observation ingest/history. Was "monitoring"/"/api/monitors" -
-- renamed to free "monitors" for the scraping-agent registry
-- (server/plugins/monitors).
local base_path = "/api/observations"

local Plugin = {
  name = 'observations',
  dependencies = {'security', 'events'},
}

function Plugin.setup(app, deps)
    local security = deps.security
    local auth, rbac, perms = security.auth, security.rbac, security.perms
    local require_auth = auth:with({require = true})
    local event_manager = deps.events.event_manager

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

        local ok, result = pcall(function()
            local observations = models.Observations:select(db_query)
            models.Items:include_in(observations, "item_id")
            local total_items = models.Observations:count(where_clause)
            return {items=observations, total_items=total_items}
        end)

        if not ok then
            return { status = 500, json = { error = result or "Unable to get the observation list." } }
        end

        return { json = {items = result.items or {}, total_items = result.total_items} }
    end))

    -- Endpoint: Ingest a new price observation, and run it through the
    -- rule engine by also creating a linked event (see
    -- plugins/events/plugin.lua's on_create hook) - source is the item's
    -- own name (no separate "site" identity exists on an observation),
    -- payload is the observation itself so a rule can match on
    -- payload.<field> too, item_id links it back for filtering. Items
    -- carry no `tags` column of their own, so an event created this way
    -- always has null tags unless a matched rule declares its own.
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

        local ok, result = pcall(models.Observations.create, models.Observations, data)

        if not ok then
            return { status = 500, json = { success = false, message = result or "Unable to add record." } }
        end

        local ok_event, event_or_err = pcall(function()
            local item = models.Items:find({id = data.item_id})
            return event_manager:create({
                source = item and item.name or nil,
                payload = cjson.encode({
                    price = data.price,
                    discount = data.discount,
                    available = data.available,
                    url = data.url,
                }),
                item_id = data.item_id,
            })
        end)

        if not ok_event then
            -- The observation itself is already saved; a rule-matching
            -- failure here is logged, not fatal, same as pibuzz's event
            -- on_create hook treats its own internal failures.
            logger:error("Failed to create event for observation: {error}", { error = tostring(event_or_err) })
        end

        return { status = 200, json = { success = true, message = "Observation added successfully.", data=result } }
    end)))

    app:delete(base_path .. "/:id", compose(require_auth, rbac:with(perms.OBSERVATIONS_DELETE))(function(self)
        local id = self.params.id

        if not id then
            return { status = 400, json = { error = "Missing observation id." } }
        end

        local opr, err = models.Observations:find({
            id=id
        }):delete()

        if not opr then
            return { status = 500, json = { error = err or "Unable to remove observation." } }
        end

        return { json = { success = true, message = "Observation removed successfully.", data = err } }
    end))
end

return Plugin
