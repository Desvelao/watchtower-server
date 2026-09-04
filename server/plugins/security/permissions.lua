-- Fixed permission catalog: each string corresponds to a real
-- rbac:with(perms.X) enforcement point somewhere in a plugin's routes.
-- Only the role -> permission-set ASSIGNMENT is dynamic/DB-backed
-- (services/roles.lua); inventing a new permission string here with no
-- matching enforcement point would be meaningless, so this table itself
-- stays hardcoded. Mirrored by hand in public/src/constants/permissions.js
-- - keep both in sync. Also mirrored (as literal arrays) in the seed
-- INSERT INTO roles in config/dataset/init.sql.
return {
  ITEMS_READ = "items:read",
  ITEMS_CREATE = "items:create",
  ITEMS_UPDATE = "items:update",
  ITEMS_DELETE = "items:delete",

  OBSERVATIONS_READ = "observations:read",
  OBSERVATIONS_CREATE = "observations:create",
  OBSERVATIONS_DELETE = "observations:delete",

  EVENTS_READ = "events:read",
  EVENTS_CREATE = "events:create",
  EVENTS_DELETE = "events:delete",

  ALERTS_READ = "alerts:read",
  ALERTS_UPDATE = "alerts:update",
  ALERTS_DELETE = "alerts:delete",

  RULES_READ = "rules:read",
  RULES_CREATE = "rules:create",
  RULES_UPDATE = "rules:update",
  RULES_DELETE = "rules:delete",

  MONITORS_READ = "monitors:read",
  MONITORS_WRITE = "monitors:write",

  JOBS_READ = "jobs:read",

  CHANNELS_READ = "channels:read",
  CHANNELS_CREATE = "channels:create",
  CHANNELS_UPDATE = "channels:update",
  CHANNELS_DELETE = "channels:delete",

  SCRAPERS_READ = "scrapers:read",
  SCRAPERS_WRITE = "scrapers:write",

  API_KEY_MANAGE = "api_key:manage",

  USERS_READ = "users:read",
  USERS_CREATE = "users:create",
  USERS_UPDATE = "users:update",
  USERS_DELETE = "users:delete",

  ROLES_READ = "roles:read",
  ROLES_CREATE = "roles:create",
  ROLES_UPDATE = "roles:update",
  ROLES_DELETE = "roles:delete",
}
