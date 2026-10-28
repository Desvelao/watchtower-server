-- Idempotently applies server/dataset/schema.sql to a fresh database.
-- Exposes a plain M.ensure() with no self-scheduling of its own - it's
-- called defensively, as the first step, from inside every OTHER boot-time
-- module's own ngx.timer.at(0, ...) callback that touches the DB
-- (bootstrap_admin.lua, observe_pending_worker.lua's start_worker), rather
-- than from a single central place. Two independently-scheduled zero-delay
-- ngx.timer.at(0, ...) callbacks have no guaranteed relative order, and
-- (confirmed empirically - see git history) cosockets are NOT available
-- directly inside init_worker_by_lua_block's own top-level flow ("API
-- disabled in the context of init_worker_by_lua*"), only inside a
-- scheduled callback - so there is no single synchronous call site that
-- could sequence this for every consumer. Calling this idempotent,
-- self-contained ensure() (its own pcall, never raises) from each
-- consumer's own callback sidesteps needing any such ordering guarantee at
-- all: whichever callback happens to run first actually applies the
-- schema, and every other caller's own call then simply no-ops.
local logger = {
  info = function(message) ngx.log(ngx.INFO, "[bootstrap-schema] " .. message) end,
  error = function(message) ngx.log(ngx.ERR, "[bootstrap-schema] " .. message) end,
}

local M = {}

-- Reproduces docker-entrypoint-initdb.d's own semantics (applies once, only
-- on a genuinely empty/fresh database) without a schema-version tracking
-- table - `roles` is the schema's first table, so its absence means this
-- database has never had the schema applied.
local function schema_already_applied(db)
  local result = db.query("SELECT to_regclass('public.roles') AS reg")
  return result[1] and result[1].reg ~= nil
end

function M.ensure()
  local ok, err = pcall(function()
    local db = require("lapis.db")

    if schema_already_applied(db) then
      logger.info("schema already present - skipping")
      return
    end

    local path = "dataset/schema.sql"
    local f, open_err = io.open(path, "r")
    if not f then
      error("cannot open " .. path .. ": " .. tostring(open_err))
    end
    local sql = f:read("*a")
    f:close()

    -- A single db.query() call with no bind params goes over Postgres'
    -- simple-query wire protocol, which natively executes a
    -- semicolon-separated multi-statement string as one implicit
    -- transaction - no need to split statements or hand-roll
    -- BEGIN/COMMIT (contrast lib/routes.lua's with_transaction, used
    -- where callers need several separately-built queries in one
    -- transaction instead of one static script).
    db.query(sql)

    logger.info("schema applied from " .. path)
  end)

  if not ok then
    logger.error("failed: " .. tostring(err))
  end
end

return M
