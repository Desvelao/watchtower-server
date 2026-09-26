-- Idempotently creates the first admin user from INITIAL_ADMIN_USERNAME/
-- INITIAL_ADMIN_PASSWORD env vars, if set. Required from nginx.conf's
-- init_worker_by_lua_block (once per nginx worker at boot), not from
-- app.lua's top-level module body: app.lua is `require`d fresh on every
-- request in dev (lua_code_cache off), and real DB I/O inside a module
-- body loaded that way hits OpenResty's "attempt to yield across C-call
-- boundary" - the actual work below is deferred into an
-- ngx.timer.at(0, ...) callback (a real coroutine context that supports
-- yielding), the same technique server/workers/observe_pending_worker.lua
-- uses for its own startup DB calls.
-- Mirrors server/workers/observe_pending_worker.lua's own worker_logger
-- shape (info/warn/error, printf-free), but is not that same object - this
-- module runs from its own init_worker_by_lua_block entry (see this file's
-- own header comment), with no access to that other module's local.
local logger = {
  warn = function(message) ngx.log(ngx.WARN, "[bootstrap-admin] " .. message) end,
  error = function(message) ngx.log(ngx.ERR, "[bootstrap-admin] " .. message) end,
}

local ok_config, config_err = pcall(require, "config")
if not ok_config then
  logger.error("failed to load config: " .. tostring(config_err))
end

local function run()
  local initial_admin_username = os.getenv("INITIAL_ADMIN_USERNAME")
  local initial_admin_password = os.getenv("INITIAL_ADMIN_PASSWORD")

  if not (initial_admin_username and initial_admin_password) then
    logger.warn("INITIAL_ADMIN_USERNAME/INITIAL_ADMIN_PASSWORD not set - skipping initial admin bootstrap")
    return
  end

  local ok, err = pcall(function()
    local db = require("lapis.db")
    local admin_role = require("models.roles"):find({ name = "admin" })
    if not admin_role then
      logger.error("cannot bootstrap: 'admin' role not found")
      return
    end

    -- ON CONFLICT DO NOTHING makes this safe across concurrent nginx
    -- workers (no check-then-insert race) and never clobbers a
    -- since-changed password on a later restart, since it only ever
    -- inserts when the username doesn't exist yet.
    db.query(
      "INSERT INTO users (username, password_hash, role_id, enabled) "
        .. "VALUES (?, ?, ?, TRUE) ON CONFLICT (username) DO NOTHING",
      initial_admin_username,
      require("plugins.security.services.password_hash").hash(initial_admin_password),
      admin_role.id
    )
  end)

  if not ok then
    logger.error("failed: " .. tostring(err))
  end
end

if ngx and ngx.worker and ngx.worker.id then
  if ngx.worker.id() == 0 then
    local ok, err = ngx.timer.at(0, run)
    if not ok then
      logger.error("failed to schedule: " .. tostring(err))
    end
  end
end
