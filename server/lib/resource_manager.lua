-- Generic CRUD/search manager wrapping a Lapis model. Configured per
-- resource (see lib/routes.lua for the query-building helpers this uses),
-- instantiated once per resource in each plugin's setup() instead of every
-- plugin hand-rolling its own list/get/delete handlers.
local db = require("lapis.db")
local route_helpers = require("lib.routes")
local Logger = require("core.logger")

local logger = Logger:new("ERROR", function(level, message)
    return string.format("[%s] %s", level, message)
end)

local M = {}

-- model: a Lapis Model (e.g. models.Items)
-- config:
--   fields_query_params    - where_params array (see lib.routes), used for
--                             both search() and its :count()
--   fields_search_params   - columns the free-text `search` query param
--                             matches against (via create_search_map_clause)
--   search_param           - request param name for free-text search
--                             (default "search")
--   updated_at_param       - column stamped to NOW() on update (default
--                             "updated_at"); pass false to disable
--   remove_fields_on_update - column names stripped from the update payload
--                             before it's written (e.g. generated columns)
--   select_fields          - columns passed to :select (default "*")
--   on_create(new_item)    - optional hook run after a successful create;
--                             errors/failures are logged, never re-thrown
function M.new(model, config)
    local _config = config or {}
    local instance = {
        _model = model,
        fields_query_params = _config.fields_query_params or {},
        fields_search_params = _config.fields_search_params or {},
        search_param = _config.search_param or 'search',
        updated_at_param = _config.updated_at_param == nil and 'updated_at' or _config.updated_at_param,
        remove_fields_on_update = _config.remove_fields_on_update,
        select_fields = _config.select_fields or '*',
        on_create = _config.on_create,
    }

    return setmetatable(instance, { __index = M })
end

function M:create(item)
    local new_item = self._model:create(item)

    if new_item and self.on_create then
        local ok, create_ok, create_err = pcall(self.on_create, new_item)
        if not ok then
            logger:error('resource_manager: on_create raised an error: {error}', { error = tostring(create_ok) })
        elseif create_ok == false then
            logger:error('resource_manager: on_create reported failure: {error}', { error = tostring(create_err) })
        end
    end

    return new_item
end

function M:_where_params(request)
    local params = {}
    for _, v in ipairs(self.fields_query_params) do
        table.insert(params, v)
    end

    if #self.fields_search_params > 0 then
        table.insert(params, {
            key = self.search_param,
            map_clause = route_helpers.create_search_map_clause(self.fields_search_params),
        })
    end

    return params
end

function M:search(request)
    local where_params = self:_where_params(request)
    local query = route_helpers.get_db_query_params_from_request_params(request, where_params)
    local where_clause = route_helpers.get_db_where_clause_from_request_params(request, where_params)

    local items = self._model:select(query, { fields = self.select_fields })
    local total_items = self._model:count(where_clause)

    return { items = items or {}, total_items = total_items }
end

function M:find(item_id)
    return self._model:find({ id = item_id })
end

function M:delete(item_id)
    local item = self._model:find({ id = item_id })

    if not item then
        error({ status = 404, message = 'Item not found' })
    end

    return item:delete()
end

function M:update(item_id, update)
    return route_helpers.with_transaction(function()
        local item = self._model:find({ id = item_id })

        if not item then
            error({ status = 404, message = 'Item not found' })
        end

        local new_data = {}
        for k, v in pairs(item) do
            new_data[k] = v
        end

        if type(update) == 'function' then
            new_data = update(item)
        else
            for k, v in pairs(update) do
                new_data[k] = v
            end
        end

        if self.remove_fields_on_update then
            for _, field in ipairs(self.remove_fields_on_update) do
                new_data[field] = nil
            end
        end

        if self.updated_at_param then
            new_data[self.updated_at_param] = db.format_date()
        end

        local ok_update = item:update(new_data)

        local data = nil
        if ok_update then
            data = self._model:find({ id = item_id })
        end

        return ok_update, data
    end)
end

return M
