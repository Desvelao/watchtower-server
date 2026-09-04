local db = require("lapis.db")
local route_helpers = require("lib.routes")
local rule_source = require("plugins.rules.services.rule_source")
local rule_expr = require("rule_expr")
local allowed_fields = require("plugins.rules.allowed_fields")

local M = {}

local ALLOWED_KEYS = {
  name = true,
  description = true,
  ["if"] = true,
  action = true,
  severity = true,
  tags = true,
  enabled = true,
}

local VALID_SEVERITIES = { low = true, medium = true, high = true, critical = true }

function M.new(rule_model, config)
  local instance = {
    _model = rule_model,
    on_change = config and config.on_change,
  }
  return setmetatable(instance, { __index = M })
end

-- Called after every successful create/update/delete so callers (e.g.
-- rule_engine's cache, see its `invalidate`) can react to a rules change.
function M:_notify_change()
  if self.on_change then
    self.on_change()
  end
end

-- Parses+validates a raw rule `source` document into a flat row ready for
-- Model:create()/item:update(). Returns (row, nil) on success or
-- (nil, err_string) on any validation failure - the route layer uses this
-- to distinguish an expected 400 from a genuine 500.
function M:_derive(source)
  if type(source) ~= "string" or source == "" then
    return nil, "source is required"
  end

  local fields, parse_err = rule_source.parse(source)
  if not fields then
    return nil, "Invalid rule source: " .. parse_err
  end

  for k in pairs(fields) do
    if not ALLOWED_KEYS[k] then
      return nil, "Unknown rule field: " .. k
    end
  end

  local name = fields.name
  if type(name) ~= "string" or name == "" then
    return nil, "name is required"
  end

  local action = fields.action
  if type(action) ~= "string" or action == "" then
    return nil, "action is required"
  end

  local if_expr = fields["if"]
  if type(if_expr) ~= "string" or if_expr == "" then
    return nil, "if is required"
  end
  local _, expr_err = rule_expr.parse(if_expr, allowed_fields)
  if expr_err then
    return nil, "Invalid 'if' expression: " .. expr_err
  end

  local enabled = fields.enabled
  if enabled == nil then
    enabled = true
  elseif type(enabled) ~= "boolean" then
    return nil, "enabled must be true or false"
  end

  local description = fields.description
  if description == nil or description == "" then
    description = db.NULL
  end

  -- Optional: overrides the matched alert's severity/tags (see
  -- services/rule_engine.lua).
  local severity = fields.severity
  if severity == nil or severity == "" then
    severity = db.NULL
  elseif type(severity) ~= "string" or not VALID_SEVERITIES[severity] then
    return nil, "severity must be one of low, medium, high, critical"
  end

  local tags = fields.tags
  if tags == nil or tags == "" then
    tags = db.NULL
  elseif type(tags) ~= "string" then
    return nil, "tags must be a comma-separated string"
  else
    local tag_list = {}
    for tag in tags:gmatch("[^,]+") do
      local trimmed = tag:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        table.insert(tag_list, trimmed)
      end
    end
    tags = #tag_list > 0 and db.array(tag_list) or db.NULL
  end

  return {
    source = source,
    name = name,
    description = description,
    condition_expression = if_expr,
    action = action,
    severity = severity,
    tags = tags,
    enabled = enabled,
  },
    nil
end

function M:create(params)
  local row, err = self:_derive(params.source)
  if not row then
    return nil, err
  end
  local item = self._model:create(row)
  self:_notify_change()
  return item, nil
end

function M:update(item_id, params)
  local item = self._model:find({ id = item_id })
  if not item then
    return nil, "Rule not found"
  end

  local row, err = self:_derive(params.source)
  if not row then
    return nil, err
  end

  row.updated_at = db.format_date()

  local ok = item:update(row)
  if not ok then
    return nil, "Update failed"
  end

  self:_notify_change()
  return self._model:find({ id = item_id }), nil
end

function M:find(item_id)
  return self._model:find({ id = item_id })
end

function M:delete(item_id)
  local item = self._model:find({ id = item_id })
  if not item then
    error({ status = 404, message = "Rule not found" })
  end
  local result = item:delete()
  self:_notify_change()
  return result
end

function M:search(request)
  local fields_query_params = { "id", "name", "action", "enabled" }
  local fields_search_params = {
    {
      key = "name",
      map_clause = function(p)
        return route_helpers.escaped_like_clause("name", p.value)
      end,
    },
    {
      key = "description",
      map_clause = function(p)
        return route_helpers.escaped_like_clause("description", p.value)
      end,
    },
    {
      key = "action",
      map_clause = function(p)
        return route_helpers.escaped_like_clause("action", p.value)
      end,
    },
  }

  local params = {}
  for _, v in ipairs(fields_query_params) do
    table.insert(params, v)
  end
  table.insert(params, {
    key = "search",
    map_clause = route_helpers.create_search_map_clause(fields_search_params),
  })

  local where_params = params
  local query = route_helpers.get_db_query_params_from_request_params(request, where_params)
  local where_clause = route_helpers.get_db_where_clause_from_request_params(request, where_params)

  local items = self._model:select(query)
  local total_items = self._model:count(where_clause)

  return {
    items = items,
    total_items = total_items,
  }
end

return M
