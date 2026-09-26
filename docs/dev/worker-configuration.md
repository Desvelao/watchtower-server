# Worker configuration

Both the embedded worker (`server/workers/observe_pending_worker.lua`,
`USE_EMBED_WORKER=1`) and the standalone worker (`worker/lua/main.lua`) build
their runtime config the same way: `shared/watchtower_worker_core/runner.lua`'s
`build_config(mode, env)` loads `WORKER_CONFIG_FILE` (a plain `.lua` file that
returns a table) via `shared/watchtower_worker_core/config_provider.lua`/`config_provider_file.lua`,
then layers `env` (a plain table of already-resolved values, keyed by env var
name) and mode-specific defaults on top. `watchtower_worker_core` is a
publishable library and never calls `os.getenv` itself — each entry point
resolves its own env vars and assembles the `env` table it passes in. A
missing/unreadable `WORKER_CONFIG_FILE` is not an error — every field just
falls back to its default (or, for `server`/`sites`, is simply absent). One
default is worth calling out: `plugins` falls back to `{}`, so a worker with
no `WORKER_CONFIG_FILE` at all (or one that doesn't set `plugins`) loads only
the five built-in role plugins and no observer type — nothing observes until
`plugins` explicitly names an observer-type plugin module (see
the `plugins` field below).

See `docker/worker/worker_config.example.lua` for a fully-commented example
covering every field below. Copy it to `worker_config/worker_config.lua` (gitignored
— see `.gitignore`) and point `WORKER_CONFIG_FILE` at it; the dev compose
stack already defaults `WORKER_CONFIG_FILE` to
`/etc/watchtower/worker_config.lua` with `../worker_config` bind-mounted
into both the `lapis` and `worker` services at that path.

## Fields

Every setting specific to one worker role lives namespaced under that role's
own name (`observer`/`scheduler`/`deliver`/`analyzer`/
`evaluator` — the exact strings `roles` below uses),
instead of at the config root — e.g. `scheduler.interval`, not
`scheduler_interval`. Only settings shared across roles, or about the
worker process itself, stay at the top level.

Every field described below as "seconds or cron expression" accepts either a
plain number of seconds (the original form, still the default in every
example) or a cron expression string — the same 5-field `"minute hour
day-of-month month day-of-week"` grammar `scheduler_tasks.cron_expression`
uses (`shared/watchtower_worker_core/cron.lua`), e.g. `"*/5 * * * *"` (every 5
minutes) or `"0 3 * * *"` (once a day at 03:00 UTC). A cron value pins the
task to real wall-clock times instead of a fixed cadence, and — unlike the
numeric form — is never jittered, since a wall-clock contract shouldn't
drift. Cron matching is minute-granularity, so polling much faster than a
minute buys nothing. `watchtower_worker_core/schedule.lua` is what resolves
either form into a concrete next-due time, shared by both the standalone
worker's task loop (`loop.lua`) and the embedded worker's per-task
`ngx.timer` scheduling (`server/workers/observe_pending_worker.lua`). An
invalid cron expression is validated once at worker boot
(`shared/watchtower_worker_core/lifecycle.lua`): it's logged as a warning and
that one task is simply never scheduled, rather than failing the whole
worker. A task's `retry_interval` (the post-failure backoff) always stays a
plain number of seconds, never a cron expression — for most tasks this isn't
a separate `WORKER_CONFIG_FILE` field at all (it just falls back to the
task's own `interval` when unset), but the heartbeat task is the one
exception: its retry backoff is exposed as its own dedicated field,
`heartbeat_retry_interval` below, specifically because `heartbeat_interval`
itself is allowed to be a cron expression and so can't safely double as the
retry value.

### Root

| Field                                                                                                                                                                              | Default                                               | Applies to                                             | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version`                                                                                                                                                                          | `"dev"`                                               | both                                                   | Self-reported in heartbeats.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `interval`                                                                                                                                                                    | `10` (embedded) / `5` (standalone)                    | both                                                   | Shared default claim/tick cadence (seconds or cron expression — see above) — each role below falls back to this when it doesn't set its own `<role>.interval`, except `scheduler`, which has its own independent, slower default (see `scheduler.interval` below). Every role's interval is honoured on its own: a role's `interval` may be shorter or longer than this root value (see "How the standalone worker schedules roles" below).                                                                                                                                                                                                                                                                                   |
| `heartbeat_interval`                                                                                                                                                               | `30`                                                  | both                                                   | Seconds (or cron expression) between worker heartbeats.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `heartbeat_retry_interval`                                                                                                                                                         | `5`                                                   | both                                                   | Seconds to wait before retrying a failed heartbeat. Unlike `heartbeat_interval`, this must always be a plain number — never a cron expression — since it's validated as a task's `retry_interval` (see the note above the table).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `worker_id`                                                                                                                                                                        | `"worker-lua"` (standalone) / `"embedded"` (embedded) | both                                                   | The worker's registered identity — used for heartbeats, job reports, and delivery claims, not just the HTTP transport. Standalone only reads this from the config file; the embedded worker always reports `"embedded"`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `report_config`                                                                                                                                                                    | `false`                                               | both                                                   | Opt-in: self-report a secret-scrubbed copy of this config in every heartbeat (see `shared/watchtower_worker_core/config_report.lua`'s allow-list, generalized                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| via each observer type's own `:reportable_config` method, for that type's own fields). |
| `roles`                                                                                                                                                                            | `{"observer"}`                                        | standalone only                                        | Array of role strings this worker process self-reports/runs, e.g. `{"observer"}`, `{"observer","scheduler"}`, `{"analyzer"}`, `{"evaluator"}`, `{"deliver"}`, or any combination — see "Scheduler role" and "Analyzer, evaluator, and deliver roles" below. The embedded worker computes its own roles from `USE_EMBED_WORKER`/`USE_EMBED_SCHEDULER`/`USE_EMBED_DELIVER`/`USE_EMBED_EVALUATOR` instead (not config-driven; `analyzer` is always included).                                                                                                                                                                                                                                                                                   |
| `mode`                                                                                                                                                                             | `"loop"`                                              | standalone only                                        | Which run style this worker process uses — `"loop"` (today's persistent per-task-interval loop), `"sequence"` (run every task once, in order, then exit), or `"sequence-interval"` (run every task once, in order, then repeat after `sequence_interval` below). See "Run styles: loop, sequence, sequence-interval" below. `--once`/`WORKER_RUN_ONCE` still take precedence over this field when given. Ignored by the embedded worker, which arms its own per-task `ngx.timer.every` directly.                                                                                                                                                                                                                                             |
| `sequence_interval` | root `interval` fallback | standalone only | Only used when `mode = "sequence-interval"`: how long to wait between one full sequence pass finishing and the next starting — a plain number of seconds, or a cron expression string (never jittered, same dual form as `interval` above). Optional: falls back to the root `interval` above when unset, same "own interval, defaulting to the shared one" pattern every role's own `interval` already follows — set it explicitly only when the pass cadence should differ from that shared default (see "Dedicating a worker to observing vs. testing" below). Still validated at startup when explicitly set: an invalid value fails fast. |
| `run_on_start`                                                                                                                                                                     | `true`                                                | both (only meaningful for `mode = "loop"`, standalone) | Whether each role's task(s) run immediately at worker boot, or wait for their first `interval`/cron match to elapse before their first run. Each role below falls back to this when it doesn't set its own `<role>.run_on_start` (mirrors the `interval`/`<role>.interval` fallback shape exactly, except `false` is itself a meaningful override, not skipped the way a falsy `interval` would be). Meaningless for `mode = "sequence"`/`"sequence-interval"` (every task is always considered due on the very first pass regardless) and for the embedded worker (never consumes `loop.lua`).                                                                                                                                                     |
| `plugins`                                                                                                                                                                          | `{}`                                                  | both                                                   | Array of Lua module path strings to `require()` at worker boot, each expected to return a `watchtower_worker_core.lifecycle` plugin table — see "How tasks get registered: the plugin/lifecycle kernel" below. Defaults to empty: nothing beyond the five built-in role plugins is loaded unless named here, so a worker wanting observing must list its chosen observer-type plugin module explicitly. A module doesn't need to already be part of this repo/image — it just needs to be on `LUA_PATH`, e.g. the `worker_plugins/` bind mount (see `dev/docker-compose.yml`/`prod/docker-compose.yml`) — to make a third-party plugin available with no code change or image rebuild. |
| `server.address`                                                                                                                                                                   | —                                                     | standalone only                                        | Base URL of the server, e.g. `http://server:8080`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `server.batch_size`                                                                                                                                                                | `10`                                                  | standalone only                                        | Observables fetched per `GET /api/observables` page.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `server.api_key`                                                                                                                                                                   | —                                                     | standalone only                                        | Least-secure of the three ways to supply the key (see below) — only reasonable in a gitignored, tightly-permissioned file.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `LOG_LEVEL` (env only)                                                                                                                                                             | `info`                                                | standalone only                                        | `debug`/`info`/`warn`/`error`. `debug` additionally logs every HTTP request and full response body the worker makes, which can include secrets (a claimed delivery batch carries channel configs such as webhook URLs) — only enable it while debugging, never in shared logs.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

### `observer`

| Field                                       | Default                       | Applies to                       | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------- | ----------------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `observer.source`                           | `"queue"`                     | both                             | Where an `"observer"`-role tick gets its next observable from — an explicit either/or, not a hybrid. `"queue"`: ONLY claims a pending `jobs` row a `"scheduler"`-role tick queued — nothing pending means this tick does nothing, there is no fallback to interval polling; a fresh deployment with no `scheduler_tasks` configured yet therefore observes nothing until one is created. `"interval"`: the original continuous "stalest enabled observable" polling, unconditionally; `scheduler_tasks` is never consulted. See "Scheduler role" below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `observer.interval`                    | root `interval` fallback | both                             | Overrides the shared root `interval` just for this role's own claim/tick cadence (seconds or cron expression — see above).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `observer.run_on_start`                     | root `run_on_start` fallback  | standalone only, `mode = "loop"` | Overrides the shared root `run_on_start` just for this role's own task.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `observer.observe.enabled`                  | `true`                        | both                              | Independent enable/disable for the main observe task itself, on top of declaring `"observer"` in `roles` above (standalone) — see "Dedicating a worker to observing vs. testing" below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `observer.test_poll.enabled`                | `true`                        | both                              | Independent enable/disable for the ad-hoc `observer_config_test_poll` task (services `POST /api/observer_configs/test` and friends). Unlike `observer.observe` above, this task has never depended on `"observer"` being in `roles` at all — only this flag and whether an observer-type plugin providing this task is loaded (`plugins` above) gate it. See "Dedicating a worker to observing vs. testing" below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `observer.test_poll.interval`          | root `interval` fallback | both                              | This task's own dedicated cadence, independent of both the shared root `interval` and `observer.interval` above (which it silently reused before this field existed). Lets it run on a different cadence than the main flow from the same worker process — see "Dedicating a worker to observing vs. testing" and "Run styles" below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `observer.observers`                        | —                             | standalone only                  | Array of `{id, type, observable_type, ...type-specific fields}` — routes observables of one server-side `observable_types.name` to one observer implementation. `id`/`type`/`observable_type` are the only fields this array itself defines; every other field an entry needs (and any state it refreshes on its own cadence) is entirely up to that entry's `type` — see that observer-type plugin's own documentation. Which observer implementation applies for a given observable type isn't configured here at all (see `server/lib/observer_type_catalog.lua`'s header comment) — it's resolved server-side, independent of which observer-type plugins a given worker happens to have loaded. `observable_type` (and any `observable_type_id`-shaped field a type declares) is purely worker-local config; the server has no notion of this mapping beyond validating an id-shaped field itself, if that type uses one. The embedded worker ignores this key entirely: it builds one observer per enabled `observable_type_id` found in `observer_configs` (already in-process, no HTTP round trip needed) — an observable type with no enabled `observer_configs` row simply gets no observer, a safe no-op. An observer `type` becomes available by naming its plugin module in the root `plugins` field above — required at worker boot, it registers itself into that build's own observer-type registry (`shared/watchtower_worker_core/observer_registry.lua`), so a third-party observer type needs no changes to this repo's worker entry points, only a `plugins` entry naming it; see `shared/watchtower_worker_core/README.md`'s "Writing a new observer type" section. |

### `scheduler`

| Field                                  | Default                      | Applies to                       | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| -------------------------------------- | ---------------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scheduler.interval`              | `30`                         | both                             | Seconds (or cron expression — see above) between "scheduler"-role ticks (evaluating `scheduler_tasks` for due tasks). Cron granularity is minute-level, so polling much faster buys nothing. Ignored unless `"scheduler"` is in `roles` (standalone) or `USE_EMBED_SCHEDULER=1` (embedded). Deliberately its own default, independent of the shared root `interval`, unless set explicitly (`scheduler.interval` itself, or the root `interval`). |
| `scheduler.reap_stale.interval`        | `60`                         | both                             | Seconds (or cron expression) between housekeeping ticks that reset any `jobs` row stuck in `'triggering'` past `scheduler.reap_stale.timeout_seconds` back to `'error'` (see `server/plugins/jobs/services/jobs.lua`'s `reap_stale`). Ignored unless `"scheduler"` is in `roles` (standalone) or `USE_EMBED_SCHEDULER=1` (embedded), same as `scheduler.interval`.                                                                                          |
| `scheduler.reap_stale.timeout_seconds` | `300`                        | both                             | How long a `'triggering'` job may go without a report before it's considered stale and reaped. Without this, a claim whose worker crashed/hung/lost connectivity mid-task would sit in `'triggering'` forever, permanently blocking any future claim for that same worker+type+target via `jobs_active_unique_idx`. Same role-gating as `scheduler.reap_stale.interval`.                                                                                         |
| `scheduler.run_on_start`               | root `run_on_start` fallback | standalone only, `mode = "loop"` | Overrides the shared root `run_on_start` just for this role's own tasks — applies to BOTH `fire_due_tasks` and `reap_stale_jobs` (one value per role, not per task name).                                                                                                                                                                                                                                                                                        |

### `deliver`

| Field                   | Default                       | Applies to                       | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------- | ----------------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deliver.source`        | `"deliveries"`                | both                             | Where a `"deliver"`-role tick gets its work from — an explicit either/or, mirroring `observer.source` above. `"deliveries"`: claims/reports directly against the `alert_deliveries` queue (`PUT /api/alert_deliveries/claim`\|`.../report`), fully independent of `scheduler_tasks`/`jobs` — supports any number of `deliver` workers draining concurrently. `"queue"`: claims a `scheduler_tasks` `type='deliver'` job instead (`PUT /api/scheduler/claim`), so this role's cadence is admin-configured via a `scheduler_tasks` row rather than this worker's own `interval` — see "Analyzer, evaluator, and deliver roles" below. |
| `deliver.interval` | root `interval` fallback | both                             | Overrides the shared root `interval` just for this role's own claim/tick cadence (seconds or cron expression — see above).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `deliver.run_on_start`  | root `run_on_start` fallback  | standalone only, `mode = "loop"` | Overrides the shared root `run_on_start` just for this role's own task.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `deliver.smtp.*`        | —                             | both                             | The SMTP relay used by "deliver"-role email channels — see "SMTP (email notifications)" below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

### `analyzer` / `evaluator`

| Field                                  | Default                       | Applies to                       | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------------------------- | ----------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `analyzer.source`                      | `"queue"`                     | both                             | Where an `"analyzer"`-role tick gets its work from — an explicit either/or, mirroring `observer.source` above. `"queue"`: ONLY claims a pending `scheduler_tasks` `type='analyze'` job (unchanged, original behavior). `"interval"`: re-runs rule matching against every currently enabled observable's latest stored observation, unconditionally, on this role's own `interval` cadence — `scheduler_tasks` is never consulted, and no `jobs` row is involved at all. See "Analyzer, evaluator, and deliver roles" below.                                                                                                                                                                                        |
| `analyzer.interval`               | root `interval` fallback | both                             | Overrides the shared root `interval` just for this role's own claim/tick (or, in `"interval"` mode, full-drain) cadence (seconds or cron expression — see above).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `analyzer.run_on_start`                | root `run_on_start` fallback  | standalone only, `mode = "loop"` | Overrides the shared root `run_on_start` just for this role's own task.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `evaluator.source`                     | `"queue"`                     | both                             | Where a `"evaluator"`-role tick gets its work from — same either/or shape as `analyzer.source`. `"queue"`: ONLY claims a pending `scheduler_tasks` `type='notify'` job (the claim hands out the task's policy scope only; the matching runs in the worker). `"interval"`: matches every candidate alert (no `alert_deliveries` row yet, or at least one in `status='error'`) against every currently enabled `notification_policies`, unconditionally, on this role's own `interval` cadence — `scheduler_tasks` is never consulted, no `jobs` row involved. In both modes the matching itself always happens in the worker's own process, never server-side — see "Analyzer, evaluator, and deliver roles" below. |
| `evaluator.interval`              | root `interval` fallback | both                             | Overrides the shared root `interval` just for this role's own claim/tick (or, in `"interval"` mode, full-drain) cadence (seconds or cron expression — see above).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `evaluator.reap_stale.interval`        | `60`                          | both                             | Seconds (or cron expression) between housekeeping ticks that reset any `alert_deliveries` row stuck in `'triggering'` past `evaluator.reap_stale.timeout_seconds` back to `'error'` (see `server/plugins/notification_channels/services/delivery_queue.lua`'s `reap_stale`) — the `"evaluator"` role's counterpart to `scheduler.reap_stale.interval` above: evaluator is the role that _produces_ `alert_deliveries` rows (via its own enqueue pass), the same relationship scheduler has to the `jobs` it fires, so it also reaps them. Ignored unless `"evaluator"` is in `roles` (standalone) or `USE_EMBED_EVALUATOR=1` (embedded), same as `evaluator.interval`.                                             |
| `evaluator.reap_stale.timeout_seconds` | `300`                         | both                             | How long an `alert_deliveries` row may sit in `'triggering'` without a report before it's considered stale and reaped. Without this, a claim whose "deliver"-role worker crashed/hung/lost connectivity mid-send would sit in `'triggering'` forever, never sent and never retried (only an `'error'` row gets reset to `'pending'` by the next enqueue pass). Same role-gating as `evaluator.reap_stale.interval`.                                                                                                                                                                                                                                                                                                     |
| `evaluator.run_on_start`               | root `run_on_start` fallback  | standalone only, `mode = "loop"` | Overrides the shared root `run_on_start` just for this role's own tasks — applies to BOTH the evaluate task and `reap_stale_deliveries` (one value per role, not per task name).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |

The embedded worker ignores `server`/`observer.observers` entirely — it talks
to the database directly, not over the HTTP API, and reads site configs
directly from `observer_configs` (any enabled `observable_type_id`).

The standalone worker's API key additionally needs `observable_types:read` (it
calls `GET /api/observable_types/:id` to resolve each observable's observable type before
dispatching an observe), on top of whatever `observables:*`/`observations:*`/
`jobs:*`/`workers:*` permissions it already needs. Any observer using
`sites_source = "remote"` needs `observer_configs:read` too (it calls
`GET /api/observer_configs/site`).

## Analyzer, evaluator, and deliver roles

All three of `analyzer`, `evaluator`, and `deliver`
have their own queue/on-demand source split
(`analyzer.source`/`evaluator.source`/`deliver.source`,
see the Fields table above) — `"queue"` mode for `analyzer`/
`evaluator` uses the same claim/report protocol as the
`observer` role's `"queue"` `observer.source` (`PUT /api/scheduler/claim`
with `type=analyze|notify`, one aggregate `PUT /api/jobs/<type>/<task_id>/ack`
report per firing) — see `shared/watchtower_worker_core/pollers/analyze.lua`/
`pollers/evaluate.lua`.

- **`analyzer`**: re-runs rule matching against each target observable's
  already-stored latest observation (no re-observe) — useful after
  adding/editing a rule, to backfill alerts against recent data, without
  waiting for the next observe. Unlike the embedded worker (which runs
  `shared/analyzer.lua` directly, in-process, with real Postgres access),
  the standalone worker runs the actual rule-matching **client-side** — see
  `shared/watchtower_worker_core/worker_rule_matcher.lua`, which reuses the
  same pure-Lua `rule_engine.expr`/`rule_engine.engine` matching core (and
  the identical `shared/rule_engine/allowed_fields.lua` vocabulary) the
  server's own rule engine uses, fed by a handful of new/extended read
  endpoints (`GET /api/rules?enabled=true`, `GET /api/observables/:id`,
  `GET /api/observable_types/:id`, `GET /api/observations?observable_id=`,
  `GET /api/alerts?rule_id=&observable_id=&created_after=` for the cooldown
  check) and one narrow write endpoint, `POST /api/alerts` (permission
  `alerts:create`, distinct from `alerts:read`/`update`/`delete`; the
  built-in `admin` and `operator` roles have it, `viewer` doesn't — see `server/plugins/alerting/
plugin.lua`'s own header comment for why this is a validating create, not
  a general alerts write API: the worker's own cooldown decision is final,
  the route does no matching/cooldown logic of its own). A standalone
  analyzer-role worker's API key therefore needs `rules:read`,
  `observables:read`, `observable_types:read`, `observations:read`,
  `alerts:read`, and `alerts:create`, on top of `workers:write`. (There is
  no server-side "analyze this observable" route: an API route must never
  itself evaluate rules, so both worker runtimes do that matching in their
  own process.)

  `analyzer.source` (see the Fields table above) picks where it gets its
  work from: by default (`"queue"`), it ONLY claims a pending
  `scheduler_tasks` `type='analyze'` job (`PUT /api/scheduler/claim`, still
  needed for this mode), with the matching itself running client-side
  (`worker_rule_matcher.lua`). With `analyzer.source = "interval"`,
  it instead unconditionally re-runs rule matching against every currently
  enabled observable's latest stored observation on this role's own
  `interval` cadence — `scheduler_tasks` is never consulted, and no
  `jobs` row is involved at all. Standalone: paginates through
  `GET /api/observables?enabled=true` via its own independent cursor
  (`shared/watchtower_worker_core/provider_http.lua`'s `new_enabled_observables_pager`) —
  deliberately separate from `observer.source = "interval"`'s own polling
  cursor, so the two can run concurrently on the same worker process without
  corrupting each other's pagination. Embedded: a single un-paginated
  `models.Observables:select(...)`, direct in-process, running
  `shared/analyzer.lua` (not `worker_rule_matcher.lua`) as always.

- **`evaluator`**: matches every currently-unnotified
  alert against `notification_policies` (see the "Notification Policies"
  app, next to Notification Channels in the UI — a policy is authored the
  same flat `if`/`channels` document shape as a rule, evaluated against an
  alert's own fields: `severity`/`tags`/`rule_id`/`observable_id`) and
  enqueues one `pending` row per matched `(alert, channel)` pair onto the
  `alert_deliveries` queue — it never sends anything itself. The matching
  always runs in the worker's own process (see
  `shared/watchtower_worker_core/notification_policy_matcher.lua`), never
  inside an API route.
  Embedded: gated behind `USE_EMBED_EVALUATOR=1`,
  independent of `USE_EMBED_WORKER`/`USE_EMBED_SCHEDULER`/`USE_EMBED_DELIVER`.
  Standalone: add `"evaluator"` to `roles`.

  `evaluator.source` (see the Fields table above)
  picks where it gets its work from, mirroring `analyzer.source` exactly.
  By default (`"queue"`), it ONLY claims a pending `scheduler_tasks`
  `type='notify'` job (`PUT /api/scheduler/claim`). The claim only hands out
  the task's policy scope (`notify_policy_ids`; absent = every enabled
  policy) — it evaluates nothing; the worker then runs the matching itself
  over that scope. With `evaluator.source =
"interval"`, it instead unconditionally matches every currently "needs
  delivery" alert (no `alert_deliveries` row yet, or at least one in
  `status='error'`) against every currently enabled `notification_policies`,
  on this role's own `interval` cadence — `scheduler_tasks` is never
  consulted, and no `jobs` row is involved at all.

  Both modes run the same **worker-side matching**, in both runtimes: see
  `shared/watchtower_worker_core/notification_policy_matcher.lua`, which
  reuses the same pure-Lua `rule_engine.expr`/`rule_engine.engine` matching
  core (and the identical
  `shared/rule_engine/notification_policy_allowed_fields.lua` vocabulary)
  the server's dry-run preview (`POST /api/notification_policies/test`)
  uses. The embedded worker runs it in-process (policies from the model,
  candidate alerts from `server/lib/alert_queries.lua`, enqueue via
  `delivery_queue:enqueue`); the standalone worker runs it over HTTP, fed by
  `GET /api/notification_policies?enabled=true`,
  `GET /api/alerts?needs_delivery=true` (a plain data filter, keyset-paged
  with `after_id` + `sort=id:asc` by `shared/watchtower_worker_core/provider_http.lua`'s
  `new_needs_delivery_alerts_pager` — keyset, not offset, because enqueuing
  removes alerts from that set while it is being drained), and one narrow
  write endpoint, `POST /api/alert_deliveries` (`workers:write` — validates
  `alert_id`/`channel_id` exist and upserts via `delivery_queue:enqueue`,
  returning `enqueued`, doing no matching/policy logic of its own, mirroring
  `POST /api/alerts`'s identical precedent for `worker_rule_matcher.lua`).
  A standalone evaluator-role worker therefore needs `alerts:read`,
  `policies:read`, and `workers:write` on its API key, in either mode. This
  split exists because an API route must never itself evaluate/decide — see
  CLAUDE.md's "worker jobs never run in an API endpoint" rule; a server-side
  "evaluate now" endpoint (and, formerly, the notify claim doing it inline)
  was deliberately rejected in favor of this client-side matcher. Every pass
  drains the whole candidate set, so an alert that matches no policy can no
  longer hold back newer alerts behind it.

  This role also owns the `alert_deliveries` queue's stale-row
  housekeeping — see `evaluator.reap_stale.*` in the Fields table above.
  A claim (`PUT /api/alert_deliveries/claim`) whose "deliver"-role worker
  crashed/hung/lost connectivity before reporting would otherwise sit in
  `'triggering'` forever, never sent and never retried; `"evaluator"` reaps
  it (not `"deliver"`) for the same reason `"scheduler"` — not
  `"observer"`/`"analyzer"` — reaps stale `jobs`: it's the role that
  _produces_ this queue's rows.

- **`deliver`**: dispatches each resolved channel group through whichever
  `notification_channels` its rows were enqueued for, reporting each
  `(alert, channel)` row's own outcome back via
  `PUT /api/alert_deliveries/report` — see
  `shared/watchtower_worker_core/notification_senders.lua`
  (the actual webhook/Discord requests) and
  `plugins/notification_channels/services/delivery_queue.lua` (the
  claim/report queue mechanics). `deliver.source` (see the Fields table
  above) picks where it gets its work from: by default (`"deliveries"`),
  it independently and continuously claims a batch directly off the
  `alert_deliveries` queue (`PUT /api/alert_deliveries/claim`, with
  `FOR UPDATE SKIP LOCKED` making this safe for more than one `deliver`
  worker to drain concurrently) — a pure queue-drainer with no
  `scheduler_tasks`/`jobs` involvement at all. With `deliver.source =
"queue"`, it instead claims a `scheduler_tasks` `type='deliver'` job
  (`PUT /api/scheduler/claim`, same protocol as `analyzer`/
  `evaluator` above) — that claim internally calls
  the same `alert_deliveries` claim and returns its result unchanged, so
  only the claim/report plumbing differs, not the actual sending; the
  worker reports both the individual delivery outcomes (same
  `PUT /api/alert_deliveries/report` as `"deliveries"` mode) and the
  wrapping job's own `ack`/`error`. A failed delivery's row resets to
  `pending` on the evaluator's next pass, so it's retried without
  re-sending to a channel that already succeeded, regardless of
  `deliver.source`. Embedded: gated behind `USE_EMBED_DELIVER=1`,
  independent of `USE_EMBED_WORKER`/`USE_EMBED_SCHEDULER`/
  `USE_EMBED_EVALUATOR`. Standalone: add `"deliver"`
  to `roles`. Nothing is ever enqueued without a
  `evaluator` running somewhere (any worker, either
  runtime) — the two roles are fully independent and commonly run together,
  but neither implies the other.

## Run styles: loop, sequence, sequence-interval

The root `mode` field (default `"loop"`) picks one of three run styles for
the standalone worker, implemented by `shared/watchtower_worker_core/lifecycle.lua`'s
`Lifecycle:run(opts)` — a thin dispatcher over `Lifecycle:run_loop`/`:run_once`/
`:run_sequence_interval`, keyed by `opts.mode`:

- **`"loop"`** (default) — today's persistent cooperative loop: every task
  runs forever, each on its own interval, interleaved with every other task
  (see "How the standalone worker schedules roles" below). This is the only
  mode where `roles_filter`/`--role`/`--roles`/`WORKER_RUN_ONCE_ROLES` don't
  apply — the loop always runs every role `roles` declares.
- **`"sequence"`** — runs every task once, in phase order (scheduler →
  observer → analyzer → evaluator → deliver), then exits. This is exactly
  `Lifecycle:run_once`'s behavior — the same one-shot pass `--once`/
  `WORKER_RUN_ONCE` trigger (see "Running as a one-shot job" below), just
  selected from the config file instead of a flag/env var, so a container
  that's always started the same way (no `--once`) can still run as a
  one-shot batch job by setting `mode = "sequence"`.
- **`"sequence-interval"`** — attempts a full `"sequence"` pass every
  `sequence_interval` (a plain number of seconds, or a cron expression —
  same dual form as `interval`), forever. Every task is *attempted* on
  every pass, in phase order, but a task only actually **runs** once its own
  `interval` (e.g. `observer.interval`, `observer.test_poll.interval`)
  has elapsed since it last ran — tracked in memory across passes, the same
  `interval`/`retry_interval` fields `"loop"` mode already reads for its own
  per-task scheduling. A task's own interval can only ever make it run
  *less* often than the pass cadence, never more — a pass, and hence any
  chance for that task to run at all, only happens that often to begin with.
  A task with no interval of its own is due on every pass, same as before
  this per-task tracking existed. This is what lets a fast
  `observer_config_test_poll` and a deliberately slow main flow share one
  `"sequence-interval"` worker — see "Dedicating a worker to observing vs.
  testing" below for a worked example. Use this mode when you want simple,
  predictable pass-based batching (e.g. "observe, analyze, evaluate, and
  deliver everything, then sleep 5 minutes") without configuring
  `scheduler_tasks`. `sequence_interval` falls back to the root `interval`
  when unset, same as any role's own interval would; the worker fails fast
  at startup if it's explicitly set to an invalid value.

**`--once`/`WORKER_RUN_ONCE` always win over `mode`**: when either is given,
the worker performs a single `run_once` pass (`mode = "sequence"`
internally) and exits, regardless of what `mode` says in the config file —
this keeps every existing cron/systemd one-shot recipe working unchanged
even for a `WORKER_CONFIG_FILE` that also sets `mode`. `mode` only takes
effect when neither flag is given. `--role`/`--roles`/`WORKER_RUN_ONCE_ROLES`
apply to both `"sequence"` and `"sequence-interval"` (each pass is a
`run_once` under the hood) — only `"loop"` mode ignores them.

An unrecognized `mode` value fails fast at worker startup with a clear
error, rather than silently falling back to a default.

The embedded worker ignores `mode`/`sequence_interval` entirely — it never
calls `Lifecycle:run_loop`/`:run_once`/`:run_sequence_interval` at all,
arming its own per-task `ngx.timer.every` directly instead (see
`server/workers/observe_pending_worker.lua`).

## Dedicating a worker to observing vs. testing

The main observe task (`observe_batch`/`observe_interval`, gated on
`"observer"` being in `roles`) and the ad-hoc `observer_config_test_poll` task
(services `POST /api/observer_configs/test` and friends, gated on nothing
role-related at all — see "Running as a one-shot job" below) both come
from loading an observer-type plugin (whichever one you configure via
`plugins`), but you don't have to run them on the same worker, or at the
same cadence:

- `observer.observe.enabled = false` excludes just the main observe task
  (the observer-type registration real observing needs stays
  registered either way, so this never breaks a *different* worker's
  observing).
- `observer.test_poll.enabled = false` excludes just the test-poller.
- `observer.test_poll.interval` gives the test-poller its own cadence,
  independent of `observer.interval`/the shared root `interval`.

In `"loop"` mode this is all you need — every task already runs on its own
independent interval, so a fast `test_poll.interval` alongside a slow
`observer.interval` (or any other role's) already works from one
process. In `"sequence-interval"` mode (see "Run styles" above), the same
two fields also work from one process, because a task's own interval now
throttles it relative to the shared pass cadence:

```lua
mode = "sequence-interval",
sequence_interval = 2,       -- fast pass cadence, matching test_poll
observer = {
  interval = 300,        -- the main flow's own deliberately slow cadence
  test_poll = {
    -- enabled defaults to true; interval unset falls back to the
    -- shared root interval (set it explicitly below instead).
    interval = 2,
  },
},
```

With this, every pass (every ~2s) attempts both tasks, but `observe_batch`
only actually runs roughly every 300s (throttled by its own interval) while
`observer_config_test_poll` runs on (almost) every pass. The same two workers
can instead run as fully separate OS processes (two `lua main.lua`
invocations, systemd units, or docker-compose services) if you'd rather keep
them isolated at the process level — e.g. one with `observer.test_poll.enabled
= false` and the main flow's own roles, another with `roles` omitting
`"observer"` and `test_poll.enabled` left at its default.

## Running as a one-shot job (cron / systemd)

The standalone worker (`worker/lua/main.lua`) is normally a persistent
process — it loops forever, running heartbeat/scheduler-fire-due/batch-drain
tasks each on their own interval (see "How tasks get registered"/"How the
standalone worker schedules roles" below). An observer entry whose type
supports periodically refreshing its own state from the server keeps that
current via its own `observer_registry:maintenance_tasks()`-registered task
(see that observer type's own module), not
as part of observing itself. Pass `--once` on the
command line, or set `WORKER_RUN_ONCE=1` (or `true`) in its environment, and
it instead performs **exactly one pass** and exits — the shape an external
scheduler (a cron job, a systemd timer, a Kubernetes `CronJob`) needs, since
none of those can drive a process that never returns. `--once` wins if both
are given.

By default a one-shot pass runs the action for every role in `roles`. Pass
`--role=<name>` (repeatable) or `--roles=a,b`, or set
`WORKER_RUN_ONCE_ROLES=a,b` in the environment (argv wins if both are given),
to restrict a given invocation to just a subset — lets one
`WORKER_CONFIG_FILE` back several separate cron entries, one per role (e.g. a
tight schedule for `"deliver"` alongside a looser one for `"scheduler"`),
without maintaining separate config files. Only restricts the five
role-specific steps below (the stale-job reap is bundled into the
`"scheduler"` step); the heartbeat always runs every invocation regardless of
`--role`. A `--role` name that isn't a known role, or that isn't
declared in `roles`, fails the pass (exit code 1, with a warning naming it)
instead of silently running nothing; the other, valid roles in the filter
still run.

A one-shot pass runs, unconditionally (no interval pacing — the per-role
intervals exist only to pace a process that runs forever, which is
meaningless for a process that exits right after):

- a heartbeat (if `notify`/`config.server` are configured) — an observer
  type with its own remotely-refreshed state is only as fresh as this run's
  own registry construction at startup (see that observer type's own docs
  for its refresh-interval field, if it has one);
- a scheduler fire-due tick and a stale-job reap, if `"scheduler"` is in
  `roles` (and selected by `--role`, if given);
- an `observe` batch drain, if `"observer"` is in `roles` **and**
  `observer.source = "queue"` (the default), or a one-shot drain of every
  currently enabled observable, if `observer.source = "interval"` instead
  (see below);
- an `analyze` batch drain, if `"analyzer"` is in `roles` **and**
  `analyzer.source = "queue"` (the default), or a one-shot drain of every
  currently enabled observable, if `analyzer.source = "interval"` instead
  (see below);
- a `notify`-evaluation batch drain, if `"evaluator"`
  is in `roles` **and** `evaluator.source = "queue"`
  (the default), or a one-shot client-side match-and-enqueue pass over every
  currently "needs delivery" alert, if
  `evaluator.source = "interval"` instead (see "Analyzer,
  evaluator, and deliver roles" above);
- a `deliver` batch drain (`alert_deliveries` directly, or a
  `scheduler_tasks` `type='deliver'` job — see `deliver.source` in the
  Fields table above), if `"deliver"` is in `roles`.

**This list is also the run order**, not just the enumeration order: a
worker with every role enabled runs scheduler → observer → analyzer →
evaluator → deliver, in that sequence, within the
same one-shot pass — `watchtower_worker_core.lifecycle.build` sorts every
task by its own `phase` (see that package's README, "Task order (`phase`)")
before `run_once` ever iterates them, specifically so this single pass can
produce a full, real chain of output (a fresh observation → the alert it
triggers → the delivery it enqueues → the delivery actually sent) instead
of each stage running before the one before it has produced anything —
e.g. `observer.source`/`analyzer.source`/`evaluator.source
= "interval"` together let one `--once` invocation exercise the whole
pipeline end to end with no pre-existing `scheduler_tasks` needed at all.

**`observer.source = "interval"` IS driven by one-shot mode**, but through a
different cadence than its continuous polling: `--once` repeats the same
per-observable step the persistent loop uses (`do_run_interval_observe`,
which observes one observable per call) until `http_provider:next()` reports
the sweep is exhausted, so it pages through every currently enabled
observable exactly once and then finishes — this
is "interval" mode's whole point for a first manual run (see its own comment
in `docker/worker/worker_config.example.lua`). The continuous "stalest
enabled observable" polling only runs under the persistent worker (`lua
main.lua`, no `--once`). Use `"queue"` mode instead for an observer whose
observing should be driven entirely by an external scheduler rather than a
one-shot full drain.
**`analyzer.source = "interval"` is also driven by one-shot mode**, but more
simply than `observer.source = "interval"`: it runs a single plain loop
(`do_run_interval_analyze_all`) over every observable — analyze has no
per-observable `jobs`/ack step the way observe does, since re-running
rule matching involves no `jobs` row of its own. It
pages through every currently enabled observable via its own independent
cursor (`shared/watchtower_worker_core/provider_http.lua`'s `new_enabled_observables_pager`,
separate from `observer.source = "interval"`'s own `next()` cursor) and
re-runs rule matching against each one's latest stored observation, once,
then finishes. Use `"queue"` mode instead for an analyzer whose work should
be driven entirely by an external scheduler rather than a one-shot full
drain.
**`evaluator.source = "interval"` is also driven by
one-shot mode**, same shape as `analyzer.source = "interval"`: a plain loop
(`do_run_interval_evaluate_notify`), no `jobs` row of its own. It pages through every currently "needs delivery" alert via its
own independent cursor (`shared/watchtower_worker_core/provider_http.lua`'s
`new_needs_delivery_alerts_pager`) and matches each one against every
currently enabled `notification_policies`, entirely client-side (see
`notification_policy_matcher.lua`), once, then finishes. Use `"queue"` mode
instead for an evaluator whose work should be driven entirely by an
external scheduler rather than a one-shot full drain.

**The ad-hoc observer-config test poller IS driven by one-shot mode too** (the
`observer_config_test_poll` task, registered by whichever observer-type
plugin you load into
`watchtower_worker_core.lifecycle`) — still unrelated to
`scheduler_tasks`/`jobs`, but drains every currently pending test request (not
just the oldest one) in that single `--once` pass, via the
same "repeat while `more`" mechanism `observer.source = "interval"` uses
above: `poll_and_run` handles at most one pending row per call and reports
back whether it found one, so `--once` keeps calling it until the queue is
empty. Since this task declares no `role`, it's also ungated by
`--role`/`WORKER_RUN_ONCE_ROLES` — every `--once` invocation always attempts
to drain it, regardless of which roles were selected for that pass. It IS
gated by `observer.test_poll.enabled` (see "Dedicating a worker to observing
vs. testing" below) - set that to `false` and it's skipped here too, same as
in `"loop"`/`"sequence-interval"` mode.

**Exit code**: `0` if every attempted action succeeded (or there was nothing
pending for any of them); non-zero if at least one action errored, or a
claimed batch's own final report failed to reach the server — an external
scheduler can alert on a non-zero exit the same way it would for any other
cron job.

See `docker/worker/watchtower-worker.service.example` +
`watchtower-worker.timer.example` for a systemd unit/timer pair, and
`docker/worker/crontab.example` for a crontab-line equivalent.

**The embedded worker has no `--once`/`WORKER_RUN_ONCE` equivalent** — it
lives inside the server's nginx worker process rather than being its own
process, so it can't itself be invoked by an external OS cron/systemd timer
the same way. Instead, `POST /api/workers/embedded/run/:role` (`workers:write`,
`:role` one of `observer`/`analyzer`/`evaluator`/
`deliver`/`scheduler`) triggers a single out-of-band pass of that role's
action, ahead of its own `ngx.timer.every` cadence — an admin action, or an
external cron curling this route, gets the same "force one pass now"
capability the standalone worker's `--once` provides. 404s if the embedded
worker isn't running (`USE_EMBED_WORKER=0`); 400s for a role this worker
doesn't currently declare (e.g. `deliver` without `USE_EMBED_DELIVER=1`). For
`analyzer`, this route honors `analyzer.source` the same way its own
periodic tick does — `"queue"` claims/reports one scheduler-fired batch job,
`"interval"` runs one full drain pass with no `jobs` row involved.

## Scheduler role

A worker declaring `"scheduler"` in `roles` (standalone) or running with
`USE_EMBED_SCHEDULER=1` (embedded, independent of `USE_EMBED_WORKER`)
periodically evaluates `scheduler_tasks` task definitions for due ones
(cron-recurring or one-shot) and, when due, generates the resulting observe
work — see the "Scheduler" plugin (`/scheduler` in the UI,
`server/plugins/scheduler/` in Lua). This is deliberately decoupled
from the `analyzer`/`observer`/`deliver` roles' own logic:

- It's its own task with its own interval, independent of the observer's
  per-observable observe step — same shape as the existing ad-hoc
  observer-config test poller (its own `ngx.timer.every` for embedded; a separate
  task in the standalone worker's loop, since that runtime has no separate
  timer/thread primitive).
- A worker declaring `"scheduler"` WITHOUT `"observer"` never polls/observes
  real observables at all — it only ever calls the "fire due tasks" step. Only an
  `"observer"`-role worker whose `observer.source` is `"queue"` (the default)
  claims the observe work a scheduler tick generates — see
  `shared/watchtower_worker_core/processors.lua`'s `do_run_pending_observe_batch` and
  `server/workers/observe_pending_worker.lua`'s `poll_pending_observe_batch`. An
  `"observer"`-role worker whose `observer.source` is `"interval"` never claims
  scheduled work at all, even if `scheduler_tasks` exist and even if this
  same worker also runs the `"scheduler"` role itself — the two settings are
  independent, so falling back to the pre-scheduler continuous-polling
  behavior needs `observer.source = "interval"` set explicitly. An
  `"analyzer"`-role worker whose `analyzer.source` is `"interval"` likewise
  never claims scheduler-fired analyze work, independent of whether it also
  runs `"scheduler"`.
- No new permission is needed beyond `workers:write` (already required for
  heartbeats) — the scheduler/claim routes reuse it, same as the existing
  worker-report routes do.
- This role also owns the `jobs` queue's stale-job housekeeping — see
  `scheduler.reap_stale.*` in the Fields table above.

A remote-fetch failure at startup (`sites_source = "remote"`, network
error or missing `observer_configs:read`) raises immediately, matching
`observer_registry`'s own construction-time-failure philosophy — same
treatment as an unknown observer `type` or a duplicate `observable_type`
mapping in `observer.observers`. Fix the config/permission and restart; there's no
retry loop around observer construction on the standalone worker (the
embedded worker's own always-on remote-sites observer does retry, once,
by falling back to an empty site list rather than aborting startup —
see `server/workers/observe_pending_worker.lua`'s `build_observer_registry`).

## The server API key (standalone only)

Resolved by `resolve_server_api_key()` in `shared/watchtower_worker_core/runner.lua`,
most-secure-first:

1. **`SERVER_API_KEY_FILE`** — an env var naming a file to read the key
   from at startup, rather than holding the value itself. Never appears in
   `docker inspect`/`ps`/`/proc/<pid>/environ` — only a path does. This is
   also the whole Docker/Compose secrets integration: a secret mounted at
   `/run/secrets/<name>` is just a file, so
   `SERVER_API_KEY_FILE=/run/secrets/server_api_key` is all that's needed.
2. **`SERVER_API_KEY`** — the plain env var.
3. **`server.api_key`** in `WORKER_CONFIG_FILE` itself — last resort.

An unreadable/empty `SERVER_API_KEY_FILE` falls through to the next source
(logged as a warning), not a crash.

Create a real key via `POST /api/auth/api_key` (needs `api_key:manage`) — a
fresh database seeds no `api_keys` rows, so the placeholder
`SERVER_API_KEY` in `dev/docker-compose.yml` never actually authenticates
until you generate one and export it (or write it into
`worker_config/worker_config.lua`/a `SERVER_API_KEY_FILE`).

## SMTP (email notifications)

Both runtimes can send `email` notification channels.
`shared/watchtower_worker_core/runner.lua`'s `build_config(mode, env)` resolves
`config.deliver.smtp` unconditionally on both, from the `SMTP_*` keys each
entry point's own `env` table supplies (a single app-wide SMTP relay shared
by every `email` notification channel; recipients/subject/body stay
per-channel, in `notification_channels_email`), but each runtime sends
through a different SMTP client, for the same reason
`server/lib/resty_webhook_transport.lua` exists for outbound
webhooks/Discord:

- **Standalone worker**: sends through `pling.notifiers.email`'s own
  LuaSocket/LuaSec socket, unchanged - a plain Lua 5.1 process has no
  trouble with real blocking sockets.
- **Embedded worker**: `server/lib/resty_mail_notifier.lua`, built on
  `lua-resty-mail` (`resty.mail`), a pure OpenResty/cosocket SMTP client
  that implements the wire protocol itself. This was needed because
  `pling.notifiers.email` is built on LuaSocket's own
  `socket.smtp`/`socket.tp`/`mime` protocol code, which internally invokes
  Lua callbacks _from_ C functions (e.g. for line/dot-stuffing processing) -
  yielding a cosocket op through that C boundary raises `attempt to yield
across C-call boundary`, a hard Lua/LuaJIT runtime restriction. An
  earlier attempt (`server/lib/resty_smtp_socket.lua`, since removed) tried
  injecting a cosocket-based _socket_ underneath pling's own SMTP
  protocol code instead - confirmed broken, since the yield happens inside
  pling's protocol layer itself, not the socket layer. `resty.mail`
  sidesteps the whole problem by never going through that protocol code at
  all.

Resolved most-secure-first, same shape as the server API key:

1. **`SMTP_PASSWORD_FILE`** — a path to a file holding the password, for
   the same Docker/Compose-secrets reasons as `SERVER_API_KEY_FILE`.
2. **`SMTP_PASSWORD`** — the plain env var.
3. **`deliver.smtp.password`** in `WORKER_CONFIG_FILE` — last resort.

The non-secret fields (`SMTP_HOST`/`SMTP_PORT`/`SMTP_USER`/`SMTP_FROM`/`SMTP_SSL`
env vars, or `deliver.smtp.host`/`.port`/`.user`/`.from`/`.ssl` in `WORKER_CONFIG_FILE`)
resolve the same env-first-then-file way: an env var that is unset **or empty**
falls through to the file value (compose files often export `${SMTP_HOST:-}`
unconditionally, so an empty variable must not mask the file), and `SMTP_SSL`
accepts `0`/`false`/`no`/`off` (any case) to turn TLS off, anything else to
turn it on. A missing/empty host means email
is simply not configured — channels of type `email` then fail per-alert
with a clear reason instead of the worker crashing.

Only **implicit TLS** is supported (`ssl = true`/`SMTP_SSL=1`, typically
port 465) — STARTTLS (port 587) is not implemented in the underlying
`pling.notifiers.email` module. Gmail supports both, so implicit TLS on
465 works with no further changes.

### Gmail setup

1. Enable 2-Step Verification on the Google account.
2. Generate an **App Password**: myaccount.google.com → Security → App
   passwords (16 characters, no spaces once copied).
3. Configure: `SMTP_HOST=smtp.gmail.com`, `SMTP_PORT=465`, `SMTP_SSL=1`,
   `SMTP_USER=<gmail address>`, `SMTP_PASSWORD=<app password>`,
   `SMTP_FROM=<gmail address>`.

### Runtime notes

See the "Both runtimes can send `email` notification channels" section
above for which SMTP client each runtime uses and why they differ
(`pling.notifiers.email` for the standalone worker,
`server/lib/resty_mail_notifier.lua`/`lua-resty-mail` for the embedded
worker). The embedded worker's image installs `lua-resty-mail` via
LuaRocks (`docker/images/dev/lapis/Dockerfile`,
`docker/images/prod/server/Dockerfile`) — the standalone worker's image
does not need it, since it never loads `resty.mail`.

## How tasks get registered: the plugin/lifecycle kernel

Both workers build their whole task list the same way now, via
`shared/watchtower_worker_core/lifecycle.lua`'s `M.build(plugins, context)`
— a small plugin system modeled on the server's own
`server/lib/plugins-service.lua` (`{name, dependencies, setup(app, deps)}`,
topologically sorted), extended with a second concept the server's plugin
system doesn't need: a plugin's `setup(context, deps)` can also return
`tasks` (an array of `{name, role?, interval, retry_interval?, once?, run}`
— the same shape `loop.lua` below already accepts), `observer_deps`
(merged into `watchtower_worker_core.observer_registry.new`'s own `deps`),
and `heartbeat_properties` (merged into the heartbeat's `properties`
payload). `shared/watchtower_worker_core/plugins/` is the five built-in
role plugins (`scheduler`, `analyzer`, `evaluator`,
`deliver`, `observer`) — each self-gates on `config.roles`/`has_role` and,
if enabled, registers that role's task(s) (`"scheduler"` registers two:
fire-due and the stale-job reap). Which plugin(s) beyond those five
built-ins actually load is config-driven, not hardcoded: both entry points
call `shared/watchtower_worker_core/plugin_loader.lua`'s
`require_configured(config.plugins, logger)`, which `require()`s each
module path in `plugins` (see the `plugins` field above) and appends the
resulting plugin table(s) to the built-in five — a path that fails to
`require` (missing/broken module) is logged and skipped rather than
crashing worker boot. Any observer-type plugin registering itself this way
(e.g. one bundled under `worker_plugins/`) is loaded like
any other configured entry, not unconditionally. A worker entry point
(`worker/lua/main.lua`, `server/workers/observe_pending_worker.lua`) just
assembles the plugin list (built-ins + configured) and a `context` table
(config, transport, logger, ...) and calls `lifecycle.build(plugins,
context)` — see `shared/watchtower_worker_core/README.md`'s "Writing a new
task plugin" for the full contract.

An observer instance's own state-refresh behavior (for a type that has one)
is _not_ one of a plugin's own `tasks` — it's a per-instance
`observer_registry:maintenance_tasks()` entry instead (see
that observer type's own module), the
per-INSTANCE counterpart to a plugin's per-TYPE tasks, aggregated into the
same task list `lifecycle.build` assembles, on whatever cadence field
that type's own config declares.

## How the standalone worker schedules roles

`lua main.lua` (no `--once`) runs one cooperative loop
(`shared/watchtower_worker_core/loop.lua`, via `lifecycle:run_loop`) over
the single task list `lifecycle.build` assembled: a heartbeat first, then
every plugin-registered task. Each task runs on its **own** interval —
`heartbeat_interval`, each role's own `<role>.interval` (falling back
to the root `interval`), and `scheduler.reap_stale.interval` — with
±20% jitter. The loop always runs the earliest-due task next and sleeps
until the next one is due, so a role's `interval` is honoured whether
it's shorter or longer than any other's (e.g. `deliver.interval = 1`
alongside a root `interval = 10` really polls every ~1s).

Tasks run **one at a time**, so a slow one (say, a large `observe` batch)
delays the others until it finishes; no task is skipped, none overlaps
another. Between any two task runs the loop re-checks what's due, so a long
`observer.source = "interval"` sweep (one observable per run) can't starve the
heartbeat or another role either. A failed task (an error, or a falsy result)
is logged and retried after its own interval (the heartbeat retries after the
shorter root `interval`).

By default every role's task(s) are also due **immediately at boot** (the
heartbeat first, then every plugin-registered task, in declared order) —
their first run doesn't wait for their `interval`/cron to elapse. Set
`run_on_start = false` at the root, or `<role>.run_on_start = false` for
just one role (see the `### Root`/per-role tables above), to defer that
role's task(s)' first run to their first `interval`/cron match instead,
the same as every later run already is. This only affects the very first
run after boot — every subsequent run is scheduled the normal way
regardless. Only meaningful for this persistent-loop run style; `"sequence"`
mode always runs every task exactly once, and `"sequence-interval"` mode
considers every task due on its very first pass regardless of `run_on_start`
— see "Run styles" above for how `"sequence-interval"` schedules every pass
after that first one (each task throttled by its own interval, on top of the
shared pass cadence).

## How the embedded worker schedules roles

The embedded worker doesn't use `loop.lua`/`lifecycle:run_loop` at all: once
`lifecycle.build` has assembled the task list (deferred into a
`ngx.timer.at(0, ...)` boot callback — the observer registry's own
construction does real DB I/O, which can't happen at module top level), it
starts **every** task — heartbeat included — on its own concurrent
`ngx.timer.every`, so a slow role never delays another the way it can on
the standalone worker's single shared loop. `POST /api/workers/embedded/run/:role`
(see below) is built on the same task list too:
`lifecycle:tasks_by_role(role)` runs every task registered for that role
exactly once, synchronously.

## Running the standalone worker in dev

The `worker` service in `dev/docker-compose.yml` is idle by default
(`entrypoint: tail -f /dev/null`) so the dev stack doesn't crash-loop before
a real key/config exists. Once you have both:

```console
cd dev
docker compose exec worker sh
# inside the container:
SERVER_API_KEY=<your key> lua main.lua
```

## Known simplification

Neither worker enforces an observe cooldown yet — the embedded worker's
`get_pending_observable()` always re-selects the single "stalest" enabled
observable (never-observed first, then whichever was observed longest ago), and the
standalone worker's `_fetch_observable_batch()` just re-paginates through every
enabled observable each full pass. With one or a handful of observables this means
continuous observing at `interval` cadence; a real per-observable cooldown
(skip observables observed within the last N seconds) is a natural follow-up once
there's more than a handful.

`analyzer.source = "interval"`'s own drain uses an independent pagination
cursor from `observer.source = "interval"`'s (`new_enabled_observables_pager`
on standalone; a fresh, un-paginated `models.Observables:select` each pass on
embedded), so the two can safely run concurrently on the same worker process
without corrupting each other's pagination.
