-- Hand-rolled CSV builder, no new Luarocks dependency - same convention as
-- lib/zip_writer.lua/crc32.lua/watchtower_worker_core/cron.lua. Used by
-- lib/export_response.lua for the alerts/workers/jobs/alert_deliveries
-- export routes (system-generated/observed records with no admin-authored
-- "source" document to export instead, unlike rules/notification_policies).
local cjson = require("cjson")

local M = {}

local function escape_cell(value)
  if value == nil or value == cjson.null then
    return ""
  end

  local str
  if type(value) == "table" then
    -- A jsonb column (already Lua-decoded), an array column, or a
    -- json_agg subselect result (e.g. alerts.deliveries) - flattened to a
    -- single JSON-encoded cell so the file stays flat/valid CSV while
    -- remaining round-trippable.
    str = cjson.encode(value)
  else
    str = tostring(value)
  end

  -- Formula-injection guard (OWASP CSV Injection mitigation): a cell whose
  -- first character would be interpreted by Excel/Sheets/LibreOffice as a
  -- formula/DDE trigger gets a leading `'` to force plain-text treatment.
  -- Must run before the quoting below so an already-prefixed cell that also
  -- contains a comma/quote/CR/LF still gets correctly quoted on top.
  if str:find("^[=+%-@\t\r]") then
    str = "'" .. str
  end

  if str:find('[,"\r\n]') then
    str = '"' .. str:gsub('"', '""') .. '"'
  end
  return str
end

-- rows: array of row tables (from a DB query/model select). columns: fixed,
-- ordered array of column keys - a Lua table's own key order via `pairs` is
-- unspecified, so callers must supply this explicitly for a stable header/
-- column order.
function M.build(rows, columns)
  local lines = { table.concat(columns, ",") }
  for _, row in ipairs(rows) do
    local cells = {}
    for _, col in ipairs(columns) do
      table.insert(cells, escape_cell(row[col]))
    end
    table.insert(lines, table.concat(cells, ","))
  end
  return table.concat(lines, "\r\n")
end

return M
