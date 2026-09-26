// The minimal API-key permission set each worker role (see WORKER_ROLES in
// ../plugins/workers/workerRoleSchemas.js) needs to operate, derived from
// docs/dev/worker-configuration.md's per-role "needs X" statements and
// cross-checked against each route's actual rbac:with(...) permission check
// (route code is ground truth where the docs and CLAUDE.md ever disagree -
// e.g. POST /api/alert_deliveries needs DELIVERIES_CREATE+DELIVERIES_UPDATE,
// not WORKERS_WRITE as an older doc pass claimed). Permissive on purpose:
// each set covers that role's default ("queue") mode plus its optional
// interval-mode/remote-sites reads, so a generated key keeps working if the
// worker's config later switches modes.
//
// This is purely a frontend UI convenience for pre-filling the API key
// creation form's permission picker (see ApiKeysView.vue) - it has no
// server-side counterpart, since a key is capped to the creating user's own
// current permissions regardless of which preset button filled the picker.
import { PERMISSIONS } from './permissions';

export const WORKER_ROLE_PERMISSIONS = {
  analyzer: [
    PERMISSIONS.WORKERS_WRITE,
    PERMISSIONS.JOBS_READ,
    PERMISSIONS.JOBS_UPDATE,
    PERMISSIONS.RULES_READ,
    PERMISSIONS.OBSERVABLES_READ,
    PERMISSIONS.OBSERVABLE_TYPES_READ,
    PERMISSIONS.OBSERVATIONS_READ,
    PERMISSIONS.ALERTS_READ,
    PERMISSIONS.ALERTS_CREATE,
  ],

  observer: [
    PERMISSIONS.WORKERS_WRITE,
    PERMISSIONS.JOBS_READ,
    PERMISSIONS.JOBS_UPDATE,
    PERMISSIONS.OBSERVABLE_TYPES_READ,
    PERMISSIONS.OBSERVATIONS_CREATE,
    PERMISSIONS.OBSERVABLES_READ,
    PERMISSIONS.OBSERVER_CONFIGS_READ,
  ],

  deliver: [
    PERMISSIONS.WORKERS_WRITE,
    PERMISSIONS.DELIVERIES_UPDATE,
    PERMISSIONS.JOBS_READ,
    PERMISSIONS.JOBS_UPDATE,
  ],

  scheduler: [
    PERMISSIONS.WORKERS_WRITE,
    PERMISSIONS.JOBS_CREATE,
  ],

  evaluator: [
    PERMISSIONS.WORKERS_WRITE,
    PERMISSIONS.JOBS_READ,
    PERMISSIONS.JOBS_UPDATE,
    PERMISSIONS.ALERTS_READ,
    PERMISSIONS.POLICIES_READ,
    PERMISSIONS.DELIVERIES_CREATE,
    PERMISSIONS.DELIVERIES_UPDATE,
  ],
};
