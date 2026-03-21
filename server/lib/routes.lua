local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local with_params = require("lapis.validate").with_params
local capture_errors = require("lapis.application").capture_errors

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

local function create_search_map_clause(columns, value)
    return function(param)
        local clause = ''
        local value = param.value
        for i,key in ipairs(columns) do
            if i > 1 then
                clause = clause .. ' or '
            end
            clause = clause .. ' ' .. key .. ' LIKE \'%' .. value ..'%\''
        end
    
        return clause
    end
end

return {
    capture_bad_request_params_validate = capture_bad_request_params_validate,
    get_optional_query_parameters = get_optional_query_parameters,
    get_db_query_params_from_request_params = get_db_query_params_from_request_params,
    get_db_where_clause_from_request_params = get_db_where_clause_from_request_params,
    create_search_map_clause = create_search_map_clause
}