local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local with_params = require("lapis.validate").with_params
local capture_errors = require("lapis.application").capture_errors
local Logger = require("core.logger")

local logger = Logger:new("ERROR", function(level, message)
    return string.format("[%s] %s", level, message)
end)

local capture_bad_request_params_validate = function(validation)
    return function (fn)
        return capture_errors(
                json_params(
                    with_params(validation,fn)
                ),
            function(self)
                return {
                status= 400,
                json = {
                    errors = self.errors
                }
                }
            end
        )
    end
end


local get_optional_query_parameters = function(validation)

    return function (fn)
        return function(self)
            local errors = {}
            for _,v in ipairs(validation) do
                local param, validate, transform = v[1], v[2], v[3]

                if self.params[param] ~= nil then
                    local ok, result = pcall(function(value, validate, transform)
                        if transform and type(transform) == 'function' then
                            value = transform(value)
                        end
                        local validation, error_validation = validate(value)

                        if not validation then
                            error(param ..': '..error_validation)
                        end
                        return value
                    end, self.params[param], validate, transform)


                    if ok then
                        self.params[param] = result
                    else
                        table.insert(errors, result)
                    end
                end
            end

            if #errors > 0 then
                return {status = 400, json= {errors=errors, message= "Error validating"}}
            end

            return fn(self)
        end
    end
end

local function get_db_where_clause_from_request_params(request, where_params)
    -- FIX: this seems that does not support multiple params, the and operator could be missing
    local request_params = request.params

    local where_clause = ''
    if request_params then
        for _,v in ipairs(where_params) do
            local key = nil
            local operator = '='
            local value = nil
            local map_clause = nil
            if type(v) == 'string'then
                key = v
            end

            if type(v) == 'table' then
                key = v.key
                operator = v.operator
                map_clause = v.map_clause
            end

            value = request_params[key]

            if value ~= nil then
                local clause = nil

                if map_clause then
                    clause = map_clause({key=key, value=value, db=db})
                else
                    clause = key .. ' ' .. operator .. ' ' .. db.escape_literal(value)
                end

                if #where_clause > 0 then
                    where_clause = where_clause..' and '
                end
                where_clause = where_clause..' ' .. clause
            end
        end
    end

    if #where_clause > 0 then
        return where_clause
    else
        return nil
    end
end

local function str_split(str, character)
    local result = {}
    for word in string.gmatch(str, "([^" .. character .. "]+)") do
        table.insert(result, word)
    end
    return result
end

local function get_db_query_params_from_request_params(request, where_params)

    local request_params = request.params
    local params = {}

    if request_params and request_params.from ~= nil then
        params.from = request_params.from
    end
    if request_params and request_params.size ~= nil then
        params.limit = request_params.size
    end

    local result = ''

    local where_clause = get_db_where_clause_from_request_params(request, where_params)
    if where_clause then
        result = result..'where'..where_clause
    end

    if request_params.sort then
        local sort_clauses = str_split(request_params.sort, ',')
        result = result..' order by'
        for i, v in ipairs(sort_clauses) do
            if(i > 1) then
                result = result .. ','
            end
            local c = str_split(v, ':')
            local key, order = c[1], c[2]

            -- key/order come straight from the request's `sort` param; only
            -- a bare identifier and asc/desc are allowed here since this is
            -- concatenated directly into the query (db.escape_literal only
            -- escapes string values, not identifiers/keywords).
            if not key or not key:match('^[%a_][%w_]*$') then
                error('Invalid sort key: ' .. tostring(key))
            end

            order = order and order:lower() or 'asc'
            if order ~= 'asc' and order ~= 'desc' then
                error('Invalid sort order: ' .. tostring(order))
            end

            result = result .. ' ' .. key .. ' ' .. order
        end
    end

    if params.from ~= nil then
        result = result..' offset '..params.from
    end

    if params.limit ~= nil then
        result = result..' limit '..params.limit
    end

    return result
end

-- Escapes LIKE/ILIKE wildcards (%, _) and the backslash escape character
-- itself in `value` before it's wrapped in db.escape_literal for a
-- LIKE/ILIKE clause - db.escape_literal alone only guards against breaking
-- out of the SQL string literal, not against a caller injecting their own
-- wildcard behavior. `operator` defaults to "LIKE"; pass "ILIKE" for a
-- case-insensitive match.
local function escaped_like_clause(column, value, operator)
    local escaped = tostring(value):gsub('([%%_\\])', '\\%1')
    return column .. ' ' .. (operator or 'LIKE') .. ' ' .. db.escape_literal('%' .. escaped .. '%')
end

-- Fallback map_clause used by create_search_map_clause for plain-string
-- search fields; delegates to escaped_like_clause so unescaped user input
-- can never reach the query.
local function default_map_clause(param)
    return escaped_like_clause(param.key, param.value)
end

local function create_search_map_clause(columns)
    return function(param)
        local clause = ''
        local value = param.value
        for i,column in ipairs(columns) do
            local key, map_clause = column, default_map_clause
            if i > 1 then
                clause = clause .. ' or '
            end
            if type(column) == 'table' then
                key = column.key
                map_clause = column.map_clause
            end
            clause = clause .. ' ' .. map_clause({key=key, value=value})
        end

        return clause
    end
end

local RELATIVE_DATE_PATTERN = '^now%-(%d+)([mhd])$'
local UNIT_SECONDS = { m = 60, h = 3600, d = 86400 }

-- Resolves a relative date keyword ("now", "now-<N>m", "now-<N>h",
-- "now-<N>d") into a concrete bare "YYYY-MM-DD HH:MM:SS" UTC wall-clock
-- string, evaluated against the current instant this function runs.
-- Anything not matching the keyword shape passes through unchanged.
local function resolve_relative_date(value)
    if value == 'now' then
        return os.date('!%Y-%m-%d %H:%M:%S')
    end

    local amount, unit = value:match(RELATIVE_DATE_PATTERN)
    if not amount then
        return value
    end

    local seconds = tonumber(amount) * UNIT_SECONDS[unit]
    return os.date('!%Y-%m-%d %H:%M:%S', os.time() - seconds)
end

-- Right-to-left middleware composition: compose(a, b, c)(fn) == a(b(c(fn))).
local function compose(...)
    local decorators = {...}

    return function(fn)
        for i = #decorators, 1, -1 do
            fn = decorators[i](fn)
        end
        return fn
    end
end

-- Turns a pcall-caught error value into a client-safe HTTP response. `err`
-- may be a table shaped {status=<int>, message=<string>} thrown
-- deliberately by service-layer code to signal a specific HTTP status, or
-- anything else (a raw Lua error string/traceback) - the latter is never
-- echoed to the client, only `fallback_message` is returned, at
-- `fallback_status` (default 500).
local function error_response(err, fallback_message, fallback_status)
    if type(err) == 'table' and err.status then
        return { status = err.status, json = { message = err.message or fallback_message } }
    end
    return { status = fallback_status or 500, json = { message = fallback_message } }
end

-- Wraps a whole route handler in a single pcall, converting any thrown
-- error into a client-safe response via error_response (logging the raw
-- error server-side first). A handler wrapped this way no longer needs its
-- own pcall around service calls - errors raised anywhere in the chain
-- (including a service's own error({status=..., message=...})) are caught
-- here. An early `return {status=400, ...}` for validation failures is
-- unaffected - that's a normal return value, not a thrown error.
local function with_error_handling(log_message, fallback_message, fallback_status)
    return function(fn)
        return function(self)
            local ok, result = pcall(fn, self)
            if not ok then
                logger:error(log_message .. ': {error}', { error = tostring(result) })
                return error_response(result, fallback_message, fallback_status)
            end
            return result
        end
    end
end

-- The installed Lapis version has no db.transaction (lapis.db's exported
-- table has no `transaction` field), so multi-statement read-modify-write
-- sequences are wrapped in a raw BEGIN/COMMIT/ROLLBACK instead. Any thrown
-- error inside `fn` rolls back and is re-raised unmodified (level 0, so a
-- structured error({status=..., message=...}) table passes through exactly
-- as thrown). Reentrant: a call made while already inside a transaction
-- just runs `fn` directly rather than emitting a second BEGIN, which
-- Postgres would treat as re-entering the same transaction rather than a
-- real nested one - the outermost call still owns the actual
-- COMMIT/ROLLBACK. Tracked via ngx.ctx (per-request/per-timer-invocation in
-- OpenResty), not a plain module-level variable, since multiple requests
-- run concurrently within one nginx worker.
local function with_transaction(fn)
    local ctx = ngx and ngx.ctx
    if ctx and ctx._in_db_transaction then
        return fn()
    end

    if ctx then
        ctx._in_db_transaction = true
    end

    db.query('BEGIN')
    local results = { pcall(fn) }

    if ctx then
        ctx._in_db_transaction = false
    end

    local ok = results[1]
    if ok then
        db.query('COMMIT')
        return unpack(results, 2)
    end
    db.query('ROLLBACK')
    error(results[2], 0)
end

-- `fields_query_params` entries for the `created_after`/`created_before` list
-- filters every searchable table shares: an absolute or relative date (see
-- resolve_relative_date) compared against the row's created_at column.
local function created_after_param()
    return {
        key = "created_after",
        map_clause = function(p)
            return "created_at >= " .. db.escape_literal(resolve_relative_date(p.value))
        end,
    }
end

local function created_before_param()
    return {
        key = "created_before",
        map_clause = function(p)
            return "created_at <= " .. db.escape_literal(resolve_relative_date(p.value))
        end,
    }
end

-- Picks `keys` off `request.params` into a plain data table, resolving the
-- copy-pasted "for _, item in ipairs({...}) do data[target] = params[key]
-- end" loop repeated in every plugin's write handlers into one place. Each
-- entry in `keys` is either a bare param name, or {param_name, target_key}
-- to rename it on the way into `data` (e.g. {"id", "observable_id"}).
local function pick_params(request, keys)
    local data = {}
    for _, item in ipairs(keys) do
        local key, target_key
        if type(item) == 'string' then
            key, target_key = item, item
        else
            key, target_key = item[1], item[2] or item[1]
        end
        data[target_key] = request.params[key]
    end
    return data
end

return {
    capture_bad_request_params_validate = capture_bad_request_params_validate,
    get_optional_query_parameters = get_optional_query_parameters,
    get_db_query_params_from_request_params = get_db_query_params_from_request_params,
    get_db_where_clause_from_request_params = get_db_where_clause_from_request_params,
    create_search_map_clause = create_search_map_clause,
    escaped_like_clause = escaped_like_clause,
    resolve_relative_date = resolve_relative_date,
    compose = compose,
    error_response = error_response,
    with_error_handling = with_error_handling,
    pick_params = pick_params,
    created_after_param = created_after_param,
    created_before_param = created_before_param,
    with_transaction = with_transaction,
}
