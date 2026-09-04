local db = require("lapis.db")
local M = {}

function M.new(monitor_model, heartbeat_model)
  local instance = {
    _model = monitor_model,
    _heartbeat_model = heartbeat_model,
  }
  return setmetatable(instance, { __index = M })
end

-- Upserts the registry row for `monitor_id`, then appends a row to the
-- `monitor_heartbeats` history log with the same fields. `last_seen_at`/
-- `updated_at`/the history row's `created_at` are always stamped
-- server-side to NOW() on receipt, regardless of any client-sent
-- timestamp - there isn't one, the request arriving IS the signal.
-- `fields.capabilities`, when present, must already be wrapped via
-- `db.array(...)` by the caller (a Lua table isn't a valid bind value on
-- its own for a Postgres array column). An *empty* array is normalized to
-- SQL NULL below rather than passed through: pgmoon's array serializer
-- infers the Postgres element type (int/text/bool) from the array's own
-- elements, so a zero-element array has nothing to infer from and fails
-- with "cannot determine type of empty array" - this can legitimately
-- happen when a monitor's capabilities are computed from its configured
-- sites (see the shared worker code in Phase 5) rather than a hardcoded
-- non-empty constant.
--
-- The two inserts are not wrapped in an explicit transaction - matches
-- lib.routes' with_transaction usage elsewhere in this codebase (used
-- where a read-modify-write actually needs atomicity; a heartbeat upsert +
-- append-only history row does not depend on both succeeding together the
-- same way).
function M:heartbeat(monitor_id, fields)
  local t = self._model:table_name()

  -- A nil in the final positional arg slot is lost by the time it
  -- reaches db.query's varargs handling (Lua's `#`/select('#', ...)
  -- undercounts a trailing nil), which then throws "missing
  -- replacement N" - db.NULL is lapis's explicit-SQL-NULL sentinel and
  -- sidesteps that entirely, so every optional field is normalized to
  -- it rather than left as a bare Lua nil.
  local version = fields.version == nil and db.NULL or fields.version
  local capabilities = (fields.capabilities == nil or #fields.capabilities == 0) and db.NULL
    or fields.capabilities
  local item_filter = fields.item_filter == nil and db.NULL
    or fields.item_filter
  local uptime_seconds = fields.uptime_seconds == nil and db.NULL
    or fields.uptime_seconds
  local config = fields.config == nil and db.NULL or fields.config

  local rows = db.query(
    string.format(
      [[
    INSERT INTO %s (monitor_id, connection_type, version, capabilities, item_filter, uptime_seconds, config, last_seen_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
    ON CONFLICT (monitor_id) DO UPDATE SET
      connection_type = EXCLUDED.connection_type,
      version = EXCLUDED.version,
      capabilities = EXCLUDED.capabilities,
      item_filter = EXCLUDED.item_filter,
      uptime_seconds = EXCLUDED.uptime_seconds,
      config = EXCLUDED.config,
      last_seen_at = NOW(),
      updated_at = NOW()
    RETURNING *
  ]],
      t
    ),
    monitor_id,
    fields.connection_type,
    version,
    capabilities,
    item_filter,
    uptime_seconds,
    config
  )

  db.query(
    string.format(
      [[
    INSERT INTO %s (monitor_id, connection_type, version, capabilities, item_filter, uptime_seconds)
    VALUES (?, ?, ?, ?, ?, ?)
  ]],
      self._heartbeat_model:table_name()
    ),
    monitor_id,
    fields.connection_type,
    version,
    capabilities,
    item_filter,
    uptime_seconds
  )

  return self._model:load(rows[1])
end

function M:get(monitor_id)
  return self._model:find({ monitor_id = monitor_id })
end

function M:list()
  return self._model:select("order by monitor_id asc")
end

-- Heartbeat counts for `monitor_id`, bucketed by `opts.bucket`
-- ('minute'|'hour'|'day', validated by the route handler before this is
-- called - passed straight into date_trunc's first arg) between
-- `opts.since` and `opts.until` (inclusive both ends). Returns one row per
-- non-empty bucket - {bucket = <timestamp>, count = <int>} - callers
-- needing zero-filled empty buckets must do that client-side.
function M:heartbeat_buckets(monitor_id, opts)
  local rows = db.query(
    string.format(
      [[
    SELECT date_trunc(?, created_at) AS bucket, COUNT(*) AS count
    FROM %s
    WHERE monitor_id = ? AND created_at >= ? AND created_at <= ?
    GROUP BY bucket
    ORDER BY bucket
  ]],
      self._heartbeat_model:table_name()
    ),
    opts.bucket,
    monitor_id,
    opts.since,
    opts.until_
  )

  local result = {}
  for _, row in ipairs(rows) do
    table.insert(result, { bucket = row.bucket, count = tonumber(row.count) })
  end
  return result
end

return M
