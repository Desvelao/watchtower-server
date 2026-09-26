-- Named phase constants a plugin sets on its own task descriptors' `phase`
-- field (see watchtower_worker_core.lifecycle's M.build) to control run
-- order within a single pass - both watchtower_worker_core.loop's
-- persistent scheduler (as the tie-break for every task being
-- simultaneously due at boot/restart) and Lifecycle:run_once's single
-- deterministic pass, where order is the only thing that decides whether a
-- fully-enabled worker's one-shot run actually produces a full chain of
-- real output (a fresh observation -> an alert -> an enqueued delivery ->
-- a sent delivery) or not.
--
-- Numeric, ascending = earlier, spaced out by 100 so a plugin can insert
-- its own task between two of these (e.g. `phases.OBSERVE + 50`) without
-- renumbering anything. Mirrors the natural pipeline a fully-enabled
-- worker's built-in roles form in one pass - each phase's own role
-- produces the next phase's input:
--   SCHEDULE  fire_due_tasks/reap_stale_jobs - queues the `jobs` rows
--             observe/analyze/notify's "queue" source mode later claims.
--   OBSERVE   observes, posts a fresh observation.
--   ANALYZE   re-runs rule matching against it, creates alert(s).
--   EVALUATE  matches alert(s) against notification_policies, enqueues
--             deliveries.
--   DELIVER   drains the delivery queue, sends.
return {
  HEARTBEAT = 0,
  SCHEDULE = 100,
  OBSERVE = 200,
  ANALYZE = 300,
  EVALUATE = 400,
  DELIVER = 500,
  -- A task that doesn't set its own `phase` (e.g. a third-party plugin
  -- unrelated to the alert pipeline, like
  -- watchtower_observer_web_scraper's ad-hoc test-poller/site-refresh
  -- tasks) runs after the whole known pipeline by default - nothing stops
  -- such a plugin from setting an earlier phase explicitly if it ever
  -- needs to influence run_once ordering.
  DEFAULT = 1000,
}
