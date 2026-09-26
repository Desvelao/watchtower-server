local db = require("lapis.db")
local jsonb_query = require("lib.jsonb_query")
local route_helpers = require("lib.routes")
local M = {}

function M.new(worker_model, heartbeat_model)
  local instance = {
    _model = worker_model,
    _heartbeat_model = heartbeat_model,
  }
  return setmetatable(instance, { __index = M })
end

-- Upserts the registry row for `worker_id`, then appends a row to the
-- `worker_heartbeats` history log with the same fields. `last_seen_at`/
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
-- happen when a worker's capabilities are computed from its configured
-- sites (see the shared worker code in Phase 5) rather than a hardcoded
-- non-empty constant.
--
-- The two inserts are not wrapped in an explicit transaction - matches
-- lib.routes' with_transaction usage elsewhere in this codebase (used
-- where a read-modify-write actually needs atomicity; a heartbeat upsert +
-- append-only history row does not depend on both succeeding together the
-- same way).
-- `fields.roles`, when present, must already be wrapped via `db.array(...)`
-- by the caller, same as `capabilities`. `fields.properties`, when
-- present, must already be wrapped via jsonb_query.encode(...) by the
-- caller (already validated against the combined property schema of every
-- declared role - see plugins/workers/plugin.lua's heartbeat route).
function M:heartbeat(worker_id, fields)
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
  local uptime_seconds = fields.uptime_seconds == nil and db.NULL
    or fields.uptime_seconds
  local config = fields.config == nil and db.NULL or fields.config
  local roles_value = (fields.roles == nil or #fields.roles == 0) and db.NULL
    or fields.roles
  local properties = fields.properties == nil and jsonb_query.encode({}) or fields.properties

  local rows = db.query(
    string.format(
      [[
    INSERT INTO %s (worker_id, connection_type, version, capabilities, uptime_seconds, config, roles, properties, last_seen_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
    ON CONFLICT (worker_id) DO UPDATE SET
      connection_type = EXCLUDED.connection_type,
      version = EXCLUDED.version,
      capabilities = EXCLUDED.capabilities,
      uptime_seconds = EXCLUDED.uptime_seconds,
      config = EXCLUDED.config,
      roles = EXCLUDED.roles,
      properties = EXCLUDED.properties,
      last_seen_at = NOW(),
      updated_at = NOW()
    RETURNING *
  ]],
      t
    ),
    worker_id,
    fields.connection_type,
    version,
    capabilities,
    uptime_seconds,
    config,
    roles_value,
    properties
  )

  db.query(
    string.format(
      [[
    INSERT INTO %s (worker_id, connection_type, version, capabilities, uptime_seconds, roles)
    VALUES (?, ?, ?, ?, ?, ?)
  ]],
      self._heartbeat_model:table_name()
    ),
    worker_id,
    fields.connection_type,
    version,
    capabilities,
    uptime_seconds,
    roles_value
  )

  local worker = self._model:load(rows[1])
  worker.properties = jsonb_query.decode(worker.properties)
  return worker
end

local function decode_worker(worker)
  if not worker then
    return worker
  end
  worker.properties = jsonb_query.decode(worker.properties)
  return worker
end

function M:get(worker_id)
  return decode_worker(self._model:find({ worker_id = worker_id }))
end

-- Mirrors lib/resource_manager.lua's own :delete shape, keyed on worker_id
-- (this table's actual primary key) rather than id - resource_manager's
-- generic :delete can't be reused as-is since it hardcodes an `id` lookup.
function M:delete(worker_id)
  local worker = self._model:find({ worker_id = worker_id })
  if not worker then
    error({ status = 404, message = "Worker not found" })
  end
  return worker:delete()
end

-- Server-side paginated/filtered/sorted worker list, mirroring the
-- resource_manager/M:search shape used by other plugins (e.g.
-- plugins/security/services/users.lua's M:list). `role`/`capability`
-- filter against the worker's own array columns (`role = ANY(roles)`,
-- same pattern as plugins/security/services/roles.lua's
-- `permission = ANY(permissions)` filter); `last_seen_after`/
-- `last_seen_before` are this resource's date-range filter (workers have
-- no meaningful created_at for this purpose - last_seen_at, the
-- heartbeat recency column, is what's actually displayed/useful here).
function M:search(request)
  local where_params = {
    {
      key = "role",
      map_clause = function(p) return db.escape_literal(p.value) .. " = ANY(roles)" end,
    },
    "connection_type",
    {
      key = "capability",
      map_clause = function(p) return db.escape_literal(p.value) .. " = ANY(capabilities)" end,
    },
    {
      key = "last_seen_after",
      map_clause = function(p)
        return "last_seen_at >= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
      end,
    },
    {
      key = "last_seen_before",
      map_clause = function(p)
        return "last_seen_at <= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
      end,
    },
    {
      key = "search",
      map_clause = route_helpers.create_search_map_clause({ "worker_id", "version" }),
    },
  }

  local query = route_helpers.get_db_query_params_from_request_params(request, where_params)
  local where_clause = route_helpers.get_db_where_clause_from_request_params(request, where_params)

  local workers = self._model:select(query)
  local total_items = self._model:count(where_clause)
  for _, worker in ipairs(workers) do
    decode_worker(worker)
  end
  return { items = workers or {}, total_items = total_items }
end

-- Heartbeat counts for `worker_id`, bucketed by `opts.bucket`
-- ('minute'|'hour'|'day', validated by the route handler before this is
-- called - passed straight into date_trunc's first arg) between
-- `opts.since` and `opts.until` (inclusive both ends). Returns one row per
-- non-empty bucket - {bucket = <timestamp>, count = <int>} - callers
-- needing zero-filled empty buckets must do that client-side.
function M:heartbeat_buckets(worker_id, opts)
  local rows = db.query(
    string.format(
      [[
    SELECT date_trunc(?, created_at) AS bucket, COUNT(*) AS count
    FROM %s
    WHERE worker_id = ? AND created_at >= ? AND created_at <= ?
    GROUP BY bucket
    ORDER BY bucket
  ]],
      self._heartbeat_model:table_name()
    ),
    opts.bucket,
    worker_id,
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
