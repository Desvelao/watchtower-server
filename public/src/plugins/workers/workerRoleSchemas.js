// Hand-mirrors server/plugins/workers/worker_role_schemas.lua - keep both
// in sync (same convention as constants/permissions.js). Fixed, hardcoded
// worker roles - NOT user-editable like observable types - a worker can
// declare more than one at once.
export const WORKER_ROLES = ['analyzer', 'observer', 'deliver', 'scheduler', 'evaluator'];

export const WORKER_ROLE_SCHEMAS = {
  // Worker's own metadata already lives in the worker's existing fixed
  // fields (connection_type/capabilities/version/uptime_seconds)
  // - nothing new needed in `properties` for it today.
  observer: [],

  // observations_analyzed is a real, self-reported counter (see
  // server/workers/observe_pending_worker.lua), not a placeholder metric.
  analyzer: [{ name: 'observations_analyzed', label: 'Observations analyzed', type: 'number' }],

  // deliveries_sent is a real, self-reported counter (see
  // shared/watchtower_worker_core/pollers/notify.lua) - a pure sender, decoupled from policy
  // evaluation (see evaluator below).
  deliver: [{ name: 'deliveries_sent', label: 'Deliveries sent', type: 'number' }],

  // jobs_fired is a real, self-reported counter (see
  // shared/watchtower_worker_core/processors.lua's do_fire_due_tasks and
  // server/workers/observe_pending_worker.lua's poll_and_fire_due_tasks), not
  // a placeholder metric.
  scheduler: [{ name: 'jobs_fired', label: 'Scheduler tasks fired', type: 'number' }],

  // deliveries_enqueued is a real, self-reported counter (see
  // shared/watchtower_worker_core/pollers/evaluate.lua) - matches alerts against
  // notification_policies and enqueues onto alert_deliveries, never sends
  // anything itself (see deliver above).
  evaluator: [{ name: 'deliveries_enqueued', label: 'Deliveries enqueued', type: 'number' }],
};
