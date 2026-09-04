local db = require("lapis.db")
local route_helpers = require("lib.routes")

local M = {}

function M.new(model)
    local instance = {
        db = model
    }
    return setmetatable(instance, { __index = M})
end

function M:create(data)

    if not data then
        return nil, "No data provided"
    end

    local record = self.db:create(data)

    if not record then
        return nil, "Error creating entry"
    end

    return record

end

function M:find(context)
    local _context = context or {}

    if not _context.kid then
        return nil, "Not found"
    end

    local query = { kid = _context.kid }
    if _context.user_id then
        query.user_id = _context.user_id
    end

    local record = self.db:find(query)

    if not record then
        return nil, "Not found"
    end

    return record

end

function M:find_all_by_user_id(user_id, options)
    if not user_id then
        return nil, "Missing user_id"
    end

    local opts = options or {}
    local where = "user_id = " .. db.escape_literal(user_id)

    if opts.search then
        where = where .. " and " .. route_helpers.escaped_like_clause("label", opts.search, "ILIKE")
    end
    if opts.status == "active" then
        where = where .. " and revoked = false"
    elseif opts.status == "revoked" then
        where = where .. " and revoked = true"
    end
    if opts.permissions then
        where = where .. " and " .. route_helpers.escaped_like_clause("permissions", opts.permissions, "ILIKE")
    end
    if opts.created_after then
        where = where .. " and created_at >= " .. db.escape_literal(route_helpers.resolve_relative_date(opts.created_after))
    end
    if opts.created_before then
        where = where .. " and created_at <= " .. db.escape_literal(route_helpers.resolve_relative_date(opts.created_before))
    end

    local query = "where " .. where .. " order by created_at desc"

    if opts.size then
        query = query .. " limit " .. tonumber(opts.size)
    end
    if opts.from then
        query = query .. " offset " .. tonumber(opts.from)
    end

    local items = self.db:select(query)
    -- Model:count prepends its own "WHERE", unlike :select - the clause
    -- here must not include it (matches lib.routes' get_db_where_clause_
    -- from_request_params, which is also passed to :count without a
    -- "where" prefix).
    local total_items = self.db:count(where)

    return { items = items, total_items = total_items }
end

function M:delete(context)
    local record, err = self:find(context)

    if not record then
        return nil, err or "Not found"
    end

    return record:delete()
end

function M:update(context, update)
    local record, err = self:find(context)

    if not record then
        return nil, err or "Not found"
    end

    return record:update(update)
end


return M
