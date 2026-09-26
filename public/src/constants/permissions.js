// Mirrors server/plugins/security/permissions.lua by hand - keep both in
// sync. The catalog is fixed in code on purpose (see that file's header
// comment); only role -> permission-set assignment is dynamic.
export const PERMISSIONS = {
  OBSERVABLES_READ: 'observables:read',
  OBSERVABLES_CREATE: 'observables:create',
  OBSERVABLES_UPDATE: 'observables:update',
  OBSERVABLES_DELETE: 'observables:delete',

  OBSERVATIONS_READ: 'observations:read',
  OBSERVATIONS_CREATE: 'observations:create',
  OBSERVATIONS_DELETE: 'observations:delete',

  OBSERVABLE_TYPES_READ: 'observable_types:read',
  OBSERVABLE_TYPES_CREATE: 'observable_types:create',
  OBSERVABLE_TYPES_UPDATE: 'observable_types:update',
  OBSERVABLE_TYPES_DELETE: 'observable_types:delete',

  ALERTS_READ: 'alerts:read',
  ALERTS_CREATE: 'alerts:create',
  ALERTS_UPDATE: 'alerts:update',
  ALERTS_DELETE: 'alerts:delete',

  RULES_READ: 'rules:read',
  RULES_CREATE: 'rules:create',
  RULES_UPDATE: 'rules:update',
  RULES_DELETE: 'rules:delete',

  SCHEDULER_READ: 'scheduler:read',
  SCHEDULER_CREATE: 'scheduler:create',
  SCHEDULER_UPDATE: 'scheduler:update',
  SCHEDULER_DELETE: 'scheduler:delete',

  WORKERS_READ: 'workers:read',
  WORKERS_WRITE: 'workers:write',
  WORKERS_DELETE: 'workers:delete',

  JOBS_READ: 'jobs:read',
  JOBS_CREATE: 'jobs:create',
  JOBS_UPDATE: 'jobs:update',
  JOBS_DELETE: 'jobs:delete',

  CHANNELS_READ: 'channels:read',
  CHANNELS_CREATE: 'channels:create',
  CHANNELS_UPDATE: 'channels:update',
  CHANNELS_DELETE: 'channels:delete',

  POLICIES_READ: 'policies:read',
  POLICIES_CREATE: 'policies:create',
  POLICIES_UPDATE: 'policies:update',
  POLICIES_DELETE: 'policies:delete',

  DELIVERIES_READ: 'deliveries:read',
  DELIVERIES_CREATE: 'deliveries:create',
  DELIVERIES_UPDATE: 'deliveries:update',

  OBSERVER_CONFIGS_READ: 'observer_configs:read',
  OBSERVER_CONFIGS_CREATE: 'observer_configs:create',
  OBSERVER_CONFIGS_UPDATE: 'observer_configs:update',
  OBSERVER_CONFIGS_DELETE: 'observer_configs:delete',

  API_KEY_MANAGE: 'api_key:manage',

  USERS_READ: 'users:read',
  USERS_CREATE: 'users:create',
  USERS_UPDATE: 'users:update',
  USERS_DELETE: 'users:delete',

  ROLES_READ: 'roles:read',
  ROLES_CREATE: 'roles:create',
  ROLES_UPDATE: 'roles:update',
  ROLES_DELETE: 'roles:delete',
};
