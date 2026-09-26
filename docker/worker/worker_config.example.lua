-- Reference WORKER_CONFIG_FILE for the standalone observe worker
-- (worker/lua/main.lua). Copy to worker_config/worker_config.lua (gitignored -
-- see .gitignore) and edit; the dev compose stack mounts
-- ../worker_config:/etc/watchtower and defaults
-- WORKER_CONFIG_FILE to /etc/watchtower/worker_config.lua (see
-- dev/docker-compose.yml). Every field here also applies to the embedded
-- worker (USE_EMBED_WORKER=1 on the `lapis` service) except `server`,
-- `worker_id`, `roles` and `observer.observers`, which embedded ignores - it
-- talks to the database directly, not over the HTTP API, is always
-- registered as "embedded", derives its roles from USE_EMBED_* flags, and
-- its one observer is hardcoded (see server/workers/observe_pending_worker.lua).
--
-- Every setting specific to one worker role lives namespaced under its own
-- role name (observer/scheduler/deliver/analyzer/evaluator,
-- matching the exact role strings `roles` below uses) instead of at the
-- config root - only settings shared across roles, or about the worker
-- process itself, sit at the top level.
return {
  -- Self-reported in heartbeats; purely informational.
  version = "0.1.0",

  -- Shared default claim/tick cadence (seconds) - every role below falls
  -- back to this when it doesn't set its own <role>.interval, except
  -- "scheduler", which has its own independent, deliberately slower
  -- default (see scheduler.interval below).
  --
  -- Every *.interval / *.reap_stale.interval / heartbeat_interval /
  -- observers[].remote_sites_refresh_interval field in this file accepts
  -- EITHER a plain number of seconds (as below) OR a cron expression
  -- string - the same 5-field "minute hour day-of-month month
  -- day-of-week" grammar scheduler_tasks.cron_expression uses (see
  -- watchtower_worker_core/cron.lua). A cron string pins the task to real
  -- wall-clock times instead of a fixed cadence, e.g.:
  --   interval = "*/5 * * * *",  -- every 5 minutes, on the clock
  --   interval = "0 3 * * *",    -- once a day, at 03:00 UTC
  -- Cron matching is minute-granularity and, unlike the numeric form,
  -- never jittered (a cron expression is a wall-clock contract). An
  -- invalid cron expression is logged as a warning at worker boot and
  -- that one task is simply never scheduled, rather than failing the
  -- whole worker. task.retry_interval (the post-failure backoff, not
  -- exposed as a WORKER_CONFIG_FILE field itself) always stays numeric.
  interval = 10,

  -- How often (seconds, or a cron expression - see interval above) to
  -- send a worker heartbeat.
  heartbeat_interval = 30,

  -- Only meaningful for mode = "loop" (the default - see below): whether
  -- each role's task(s) run immediately at worker boot, or wait for their
  -- first interval/cron match to elapse first. Defaults to true
  -- (today's behavior - every task runs immediately at boot). Each role
  -- below may override this for just its own task(s) via its own
  -- run_on_start field (e.g. scheduler.run_on_start), falling back to this
  -- root value when it doesn't set one.
  -- run_on_start = false,

  -- The worker's registered identity - used far beyond just the HTTP
  -- transport (heartbeats, job reports, delivery claims all key off it).
  -- Standalone-only - the embedded worker always reports "embedded".
  worker_id = "worker-lua",

  -- Which role(s) this worker process self-reports/runs. Standalone-only -
  -- the embedded worker computes its own roles from USE_EMBED_WORKER/
  -- USE_EMBED_SCHEDULER/USE_EMBED_DELIVER/
  -- USE_EMBED_EVALUATOR (see
  -- shared/watchtower_worker_core/runner.lua's build_config; "analyzer" is
  -- always included there). Defaults to
  -- {"observer"} if omitted. A worker declaring "scheduler" without
  -- "observer" only ever evaluates due tasks - it never polls/observes
  -- observables itself. "analyzer"/"evaluator"/
  -- "deliver" each have their own queue/on-demand source split
  -- (analyzer.source/evaluator.source/deliver.source
  -- above) - see docs/dev/worker-configuration.md's "Analyzer,
  -- evaluator, and deliver roles". "deliver" is a
  -- pure sender that drains alert_deliveries - fully independent of
  -- "evaluator" (which matches alerts against
  -- notification_policies and enqueues onto that same queue); a worker can
  -- declare either, both, or neither.
  roles = { "observer" },
  -- roles = { "observer", "scheduler" },
  -- roles = { "scheduler" }, -- scheduler-only: never observes
  -- roles = { "observer", "analyzer", "evaluator", "deliver", "scheduler" },

  -- Which run style this worker process uses. Standalone-only. Defaults to
  -- "loop" if omitted, so leaving this out keeps today's behavior:
  --   "loop"             - persistent cooperative loop (watchtower_worker_core/loop.lua):
  --                        every task above runs forever, each on its own
  --                        <role>.interval, interleaved.
  --   "sequence"         - runs every task once, in order, then exits.
  --                        Equivalent to invoking `lua main.lua --once`, but
  --                        config-driven rather than flag-driven. --once/
  --                        WORKER_RUN_ONCE still take precedence over this
  --                        field when given.
  --   "sequence-interval" - runs every task once, in order, then waits
  --                        `sequence_interval` (below) before doing the
  --                        whole sequence again, forever. A task only
  --                        actually runs once ITS OWN interval (e.g.
  --                        observer.interval, observer.test_poll.interval)
  --                        has elapsed since it last ran, never more often
  --                        than sequence_interval itself - see
  --                        observer.test_poll's own comment below for a
  --                        worked example (a fast test-poller alongside a
  --                        deliberately slow main flow, from one worker).
  -- mode = "sequence",
  -- mode = "sequence-interval",

  -- Only used when mode = "sequence-interval": how long to wait between one
  -- full sequence pass finishing and the next starting. Same dual form as
  -- the root interval above - a plain number of seconds, or a cron
  -- expression string (never jittered). Optional: falls back to the root
  -- interval above when omitted, same "own interval, defaulting to the
  -- shared one" pattern every role's own interval already follows - only
  -- set this explicitly when the pass cadence should differ from that
  -- shared default (e.g. a fast pass alongside a deliberately slow
  -- per-role interval, as in observer.test_poll's own comment below).
  -- sequence_interval = 300,
  -- sequence_interval = "*/5 * * * *", -- every 5 minutes, on the clock

  -- Array of Lua module path strings to require() at worker boot, each
  -- expected to return a watchtower_worker_core.lifecycle plugin table
  -- ({name, dependencies?, setup} - see
  -- shared/watchtower_worker_core/README.md's "Writing a new task
  -- plugin"/"Writing a new observer type"). Applies to BOTH runtimes, like
  -- observer.source above. Defaults to {} - nothing beyond the five built-in
  -- role plugins (scheduler/analyzer/evaluator/deliver/observer) is loaded
  -- unless named here, so "observer" role observing needs
  -- watchtower_observer_web_scraper.plugin listed explicitly, as below. A
  -- plugin module doesn't need to already be part of this repo/image - it
  -- just needs to be on LUA_PATH, e.g. the worker_plugins/ bind mount (see
  -- dev/docker-compose.yml) - to make a third-party plugin available with no
  -- code change or rebuild, only this list.
  plugins = {
    "watchtower_observer_web_scraper.plugin",
  },

  -- "observer"-role settings.
  observer = {
    -- Where an "observer"-role tick gets its next observable from - applies
    -- to BOTH runtimes (unlike `roles` above, this one field IS read by the
    -- embedded worker too, from this same file). An explicit either/or, not
    -- a hybrid:
    --   "queue" (default) - ONLY claims work generated by a "scheduler"-role
    --     tick (see docs/dev/worker-configuration.md's "Scheduler role"
    --     section). Nothing pending means this tick does nothing - no
    --     fallback to interval polling. Observes nothing until at least one
    --     scheduler_tasks task is configured.
    --   "interval" - the original continuous "stalest enabled observable" polling,
    --     unconditionally. scheduler_tasks are never consulted - this worker
    --     ignores scheduling entirely.
    source = "queue",
    -- source = "interval",

    -- Optional override of the shared root interval above, just for
    -- this role's own claim/tick cadence (number of seconds, or a cron
    -- expression - see the root interval's own comment above).
    -- interval = 10,

    -- Optional override of the shared root run_on_start above, just for
    -- this role's own task (mode = "loop" only - see the root run_on_start's
    -- own comment above).
    -- run_on_start = false,

    -- Independent enable/disable for the main observe task itself, on top
    -- of declaring "observer" in `roles` above. Applies to BOTH runtimes.
    -- Defaults to true - leaving this out keeps today's behavior. Mostly
    -- useful alongside test_poll.enabled below, to dedicate one worker to
    -- just this task and another to just servicing test requests (or the
    -- reverse) - see docs/dev/worker-configuration.md.
    observe = {
      enabled = true,
      -- enabled = false,
    },

    -- The ad-hoc "test this scraper config against a URL" poller
    -- (observer_config_test_poll, registered by
    -- watchtower_observer_web_scraper.plugin above whenever it's loaded -
    -- serves POST /api/observer_configs/test and friends). Unlike the main
    -- observe task, this one has never depended on "observer" being in
    -- `roles` at all - only these two settings gate it. Applies to BOTH
    -- runtimes. Defaults preserve today's behavior exactly (always on,
    -- sharing the shared root interval above).
    test_poll = {
      -- enabled = false,

      -- Its own dedicated cadence, independent of the shared root
      -- interval above and of observer.interval above - falls
      -- back to the shared root interval when omitted. Lets one
      -- worker service test requests on a fast cadence while the main
      -- flow's own role intervals (observer/analyzer/evaluator/
      -- deliver/scheduler above) stay deliberately slow, all from the same
      -- process:
      --   * mode = "loop" (the default): each task already runs on its own
      --     independent interval, so this Just Works with no other change.
      --   * mode = "sequence-interval": every task is still attempted on
      --     every pass, but a task now only actually runs once its OWN
      --     interval (this field, or a role's own interval) has
      --     elapsed since it last ran - never more often than the pass
      --     cadence (sequence_interval below), but as much less often as
      --     its own interval says. E.g. sequence_interval = 2,
      --     observer.interval = 300, test_poll.interval unset
      --     (or <= 2): the pass ticks every 2s, test_poll runs on (almost)
      --     every tick, the main observe task only actually runs roughly
      --     once every 300s.
      --   * mode = "sequence"/--once: irrelevant - every task always runs
      --     exactly once regardless of interval, same as always.
      -- interval = 5,
    },

    -- Observer definitions - each entry routes observables of one observable type (a
    -- server-side observable_types.name) to one observer implementation. `type`
    -- selects the implementation (currently only "web_scraper" exists,
    -- worker_plugins/watchtower_observer_web_scraper/observers/web_scraper.lua); `observable_type` is this worker's own
    -- local mapping from that name to this observer - the server has no
    -- notion of this mapping at all: routing to a concrete handler is
    -- decided by the worker's own config, not something the server
    -- dictates.
    --
    -- An observer `type` becomes available simply by `require`-ing its
    -- module once at worker boot - it self-registers with
    -- watchtower_worker_core.observer_registry (main.lua already does this
    -- for "web_scraper"). A third-party observer type module written
    -- outside this repo works the same way - see
    -- shared/watchtower_worker_core/README.md's "Writing a new observer
    -- type" section.
    -- Only used by the standalone worker; the embedded worker ignores this
    -- key entirely - it builds one DB-backed web_scraper observer per
    -- enabled observable_type_id found in observer_configs directly (it's
    -- already in-process there, see server/workers/observe_pending_worker.lua).
    observers = {
      -- {
      --   id = "product_scraper",
      --   type = "web_scraper",
      --   observable_type = "product",
      --   -- url_property = "url",  -- optional, defaults to "url" - which of
      --   -- this observable type's `properties` holds the URL to scrape.
      --
      --   -- sites_source = "local" (default) reads `sites` below, a static
      --   -- list baked into this file. sites_source = "remote" instead
      --   -- fetches the current site list from the server, via the generic
      --   -- Observer Configs UI/API (GET /api/observer_configs/site) -
      --   -- lets an operator manage sites centrally instead of keeping a
      --   -- copy in every worker's own config file. Requires the API key
      --   -- below to also have `observer_configs:read`. Must also set
      --   -- remote_source = "observer_configs" and observable_type_id
      --   -- below - that's the only supported remote source.
      --   -- sites_source = "remote",
      --
      --   -- Required together with sites_source = "remote".
      --   -- observable_type_id must match a real observable_types.id.
      --   -- remote_source = "observer_configs",
      --   -- observable_type_id = 1,
      --
      --   -- Only meaningful when sites_source = "remote": how often
      --   -- (seconds, or a cron expression - see the root interval's
      --   -- own comment above) THIS observer re-fetches its own site list from the
      --   -- server, as part of its own :run (see
      --   -- worker_plugins/watchtower_observer_web_scraper/observers/web_scraper.lua) - a "remote" observer
      --   -- otherwise only fetches its site list once, at construction
      --   -- time. Defaults to 60 if omitted. This is entirely this one
      --   -- entry's own setting - every "remote" entry refreshes on its
      --   -- own cadence, independently of any other observer this worker
      --   -- declares. A site created/edited on the server takes effect on
      --   -- this worker's next observe past that interval, no restart
      --   -- needed.
      --   -- remote_sites_refresh_interval = 60,
      --
      --   sites = {
      --     -- Ignored when sites_source = "remote". Same shape as
      --     -- server/plugins/observer_configs's `POST /api/observer_configs`
      --     -- body - field keys must match the observable type's
      --     -- observation_schema property names.
      --     -- {
      --     --   name = "example-site",
      --     --   urls_match = { "^https?://example%.com/" },
      --     --   fields = {
      --     --     price = { selector = { ".price" } },
      --     --     discount = { selector = { ".discount" } },
      --     --     available = { selector = { ".availability" } },
      --     --   },
      --     -- },
      --   },
      -- },
    },
  },

  -- "scheduler"-role settings.
  scheduler = {
    -- How often (seconds, or a cron expression - see the root
    -- interval's own comment above) a "scheduler"-role tick evaluates
    -- scheduler_tasks for due tasks (see
    -- docs/dev/worker-configuration.md's "Scheduler role" section). Cron
    -- granularity is minute-level, so polling much faster buys nothing.
    -- Ignored unless "scheduler" is declared in `roles` above.
    -- Deliberately its own default (30s), not the shared root interval
    -- above, unless set explicitly here (or via the root interval).
    interval = 30,

    -- Housekeeping: resets any `jobs` row stuck in 'triggering' back to
    -- 'error', once it's gone longer than .timeout_seconds without a report
    -- (see server/plugins/jobs/services/jobs.lua's reap_stale). Ignored
    -- unless "scheduler" is declared in `roles` above, same as
    -- scheduler.interval - a worker that evaluates scheduler_tasks is
    -- also the one responsible for keeping the shared `jobs` queue healthy.
    reap_stale = {
      -- How often (seconds, or a cron expression - see the root
      -- interval's own comment above) the housekeeping tick runs.
      interval = 60,
      -- How long (seconds) a 'triggering' job may go without a report before
      -- it's considered stale and reaped. Without this, a claim whose worker
      -- crashed/hung/lost connectivity mid-task would sit in 'triggering'
      -- forever, permanently blocking any future claim for that same
      -- worker+type+target (jobs_active_unique_idx).
      timeout_seconds = 300,
    },

    -- Optional override of the shared root run_on_start above, just for
    -- this role's own tasks (fire_due_tasks AND reap_stale_jobs - mode =
    -- "loop" only, see the root run_on_start's own comment above).
    -- run_on_start = false,
  },

  -- "deliver"-role settings.
  deliver = {
    -- Where a "deliver"-role tick gets its work from - applies to BOTH
    -- runtimes, same shape as observer.source above. An explicit either/or:
    --   "deliveries" (default) - claims/reports directly against the
    --     alert_deliveries queue (PUT /api/alert_deliveries/claim|report),
    --     fully independent of scheduler_tasks/jobs. Supports any number of
    --     "deliver" workers draining concurrently (FOR UPDATE SKIP LOCKED).
    --   "queue" - claims a scheduler_tasks type='deliver' job instead
    --     (PUT /api/scheduler/claim), so this role's cadence is admin-
    --     configured via a scheduler_tasks row rather than this worker's own
    --     interval - see docs/dev/worker-configuration.md's "Analyzer,
    --     evaluator, and deliver roles" section.
    source = "deliveries",
    -- source = "queue",

    -- Optional override of the shared root interval above, just for
    -- this role's own claim/tick cadence (number of seconds, or a cron
    -- expression - see the root interval's own comment above).
    -- interval = 10,

    -- Optional override of the shared root run_on_start above, just for
    -- this role's own task (mode = "loop" only - see the root run_on_start's
    -- own comment above).
    -- run_on_start = false,

    -- The SMTP relay used by "email" notification channels - a single,
    -- app-wide setting (not per-channel). Resolved on both runtimes, and
    -- both can actually send: this standalone worker sends through
    -- pling.notifiers.email's own LuaSocket/LuaSec socket, while the
    -- embedded worker sends through a separate lua-resty-mail-based client
    -- (server/lib/resty_mail_notifier.lua) - see
    -- docs/dev/worker-configuration.md's "SMTP (email notifications)"
    -- section for why they differ. Resolution precedence, most-secure-first:
    -- SMTP_PASSWORD_FILE (a path - Docker/Compose secrets integration, same
    -- as SERVER_API_KEY_FILE below) > SMTP_PASSWORD env var >
    -- smtp.password below (least secure). Non-secret fields resolve the
    -- same way: SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_FROM/SMTP_SSL env vars
    -- override the fields below. Only implicit TLS is supported (ssl=true,
    -- typically port 465) - not STARTTLS/port 587. See
    -- docs/dev/worker-configuration.md's "SMTP (email notifications)"
    -- section.
    -- smtp = {
    --   host = "smtp.gmail.com",
    --   port = 465,
    --   user = "you@gmail.com",
    --   -- password = "...",  -- prefer SMTP_PASSWORD_FILE/SMTP_PASSWORD instead
    --   from = "you@gmail.com",
    --   ssl = true,
    -- },
  },

  -- "analyzer"-role settings. The actual rule-matching runs client-side in
  -- this worker (shared/watchtower_worker_core/worker_rule_matcher.lua),
  -- regardless of `source` below - an analyzer-role API key needs
  -- rules:read, observables:read, observable_types:read, observations:read,
  -- alerts:read, and alerts:create, on top of workers:write - see
  -- docs/dev/worker-configuration.md's "Analyzer, evaluator,
  -- and deliver roles" section.
  analyzer = {
    -- Where an "analyzer"-role tick gets its work from - same shape as
    -- observer.source above. "queue" (default): ONLY claims a pending
    -- scheduler_tasks type='analyze' job. "interval": re-runs rule matching
    -- against every currently enabled observable's latest stored
    -- observation (no re-observe), on this role's own interval cadence,
    -- unconditionally - scheduler_tasks is never consulted, no jobs row
    -- involved.
    source = "queue",
    -- source = "interval",

    -- Optional override of the shared root interval above, just for
    -- this role's own claim/tick (or, in "interval" mode, full-drain)
    -- cadence (number of seconds, or a cron expression - see the root
    -- interval's own comment above).
    -- interval = 10,

    -- Optional override of the shared root run_on_start above, just for
    -- this role's own task (mode = "loop" only - see the root run_on_start's
    -- own comment above).
    -- run_on_start = false,
  },

  -- "evaluator"-role settings - same either/or shape
  -- as analyzer above.
  evaluator = {
    -- Where an "evaluator"-role tick gets its work
    -- from. "queue" (default): ONLY claims a pending scheduler_tasks
    -- type='notify' job (matching/enqueueing happens server-side inside the
    -- claim). "interval": matches every candidate alert (one with no
    -- alert_deliveries row yet, or with at least one in status='error')
    -- against every currently enabled notification_policies, on this
    -- role's own interval cadence, unconditionally - scheduler_tasks
    -- is never consulted, no jobs row involved. Unlike "queue" mode, the
    -- matching itself happens entirely in THIS worker's own process (see
    -- shared/watchtower_worker_core/notification_policy_matcher.lua) - the
    -- server only ever answers narrow reads/writes, never runs the
    -- matching logic on this worker's behalf.
    source = "queue",
    -- source = "interval",

    -- Optional override of the shared root interval above, just for
    -- this role's own claim/tick (or, in "interval" mode, full-drain)
    -- cadence (number of seconds, or a cron expression - see the root
    -- interval's own comment above).
    -- interval = 10,

    -- Optional override of the shared root run_on_start above, just for
    -- this role's own tasks (the evaluate task AND reap_stale_deliveries -
    -- mode = "loop" only, see the root run_on_start's own comment above).
    -- run_on_start = false,
  },

  -- Standalone-only: how this worker reaches the server. The API key
  -- comes from (most-secure-first): SERVER_API_KEY_FILE (a path to a
  -- separately-permissioned secret file - how Docker/Compose secrets
  -- integrate too), the SERVER_API_KEY env var, or `server.api_key`
  -- below (least secure - only reasonable in a gitignored/tightly
  -- permissioned file). Create a real key via POST /api/auth/api_key
  -- (needs api_key:manage; see docs/dev/README.md) before using this for
  -- real - a fresh dev database seeds no api_keys rows.
  server = {
    address = "http://server:8080",
    -- api_key = "akey_...",
    batch_size = 10,
  },

  -- Opt-in (default off): self-report a secret-scrubbed copy of this
  -- config in every heartbeat (see shared/watchtower_worker_core/config_report.lua).
  report_config = false,
}
