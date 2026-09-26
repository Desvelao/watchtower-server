-- The worker roles - the exact strings a worker self-reports as `roles` in
-- its heartbeat and declares in `config.roles`, and the single definition
-- both worker runtimes, the run_once role filter, and the server's
-- worker_role_schemas.lua (which validates heartbeats against it) share.
-- (public/src/plugins/workers/workerRoleSchemas.js mirrors it by hand.)
local M = {}

M.ROLES = { "analyzer", "observer", "deliver", "scheduler", "evaluator" }

-- True if `roles` (an array of role strings, e.g. config.roles) declares
-- `name`. Also accepts nil (a worker with no declared roles).
function M.has_role(roles, name)
  if not roles then
    return false
  end
  for _, r in ipairs(roles) do
    if r == name then
      return true
    end
  end
  return false
end

return M
