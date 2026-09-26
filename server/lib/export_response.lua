-- Shared JSON/CSV response formatting for a "export the current (filtered)
-- list" route - alerts/workers/jobs/alert_deliveries are system-generated/
-- observed records with no import counterpart, unlike the authored-config
-- exports elsewhere in this codebase (rules/notification_policies/
-- notification_channels/scheduler_tasks), so they only need this read side.
local csv_writer = require("lib.csv_writer")

local M = {}

-- self.params.format selects "csv" or the default "json". `columns` is the
-- fixed, ordered column list used for CSV (JSON already preserves each
-- row's own keys, so it needs no fixed list). `basename`/`description`
-- mirror every existing export route's own filename/description
-- convention (e.g. "alerts_export_2026-09-25.json",
-- { description = "Alerts", items = ... }).
function M.respond(self, items, columns, basename, description)
  local format = self.params.format == "csv" and "csv" or "json"
  local date = os.date("%Y-%m-%d")

  if format == "csv" then
    return {
      status = 200,
      content_type = "text/csv",
      headers = {
        ["Content-Disposition"] = 'attachment; filename="' .. basename .. "_export_" .. date .. '.csv"',
      },
      layout = false,
      csv_writer.build(items, columns),
    }
  end

  return {
    status = 200,
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Disposition"] = 'attachment; filename="' .. basename .. "_export_" .. date .. '.json"',
    },
    layout = false,
    json = { description = description, items = items },
  }
end

return M
