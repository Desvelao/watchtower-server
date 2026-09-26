-- watchtower-server schema. Applied by Postgres' docker-entrypoint-initdb.d on
-- first boot only - there is no migration system. Changing this file
-- requires recreating the volume:
--   cd dev && docker compose down -v && docker compose up -d

-- ===================== Users, roles, API keys =====================

CREATE TABLE roles (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL UNIQUE,
  -- Fixed permission catalog lives in code
  -- (server/plugins/security/permissions.lua / frontend
  -- constants/permissions.js) - only role -> permission-set assignment is
  -- dynamic. Values are validated against that catalog in
  -- services/roles.lua, not by a DB constraint.
  permissions VARCHAR(255)[] NOT NULL DEFAULT '{}',
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  username VARCHAR(255) NOT NULL UNIQUE,
  -- Self-describing string, e.g.
  -- "scrypt$n=16384,r=8,p=1$<b64 salt>$<b64 hash>" (see
  -- services/password_hash.lua) so cost params can change later without
  -- invalidating already-stored hashes.
  password_hash VARCHAR(255) NOT NULL,
  role_id INTEGER NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
  -- Checked live on every request (services/auth.lua's `with`), not just
  -- at login, so disabling an account takes effect immediately.
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX users_role_id_idx ON users (role_id);

CREATE TABLE api_keys (
  id SERIAL PRIMARY KEY,
  -- A real FK to users.id, not a bare `username VARCHAR` (which would
  -- silently orphan a user's keys on rename) - deleting a user deletes
  -- their keys.
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kid VARCHAR(255) NOT NULL UNIQUE,
  label VARCHAR(255) NOT NULL,
  hash_secret VARCHAR(255) NOT NULL,
  permissions TEXT DEFAULT NULL,
  revoked BOOLEAN NOT NULL DEFAULT FALSE,
  revoked_reason TEXT DEFAULT NULL,
  expires_at TIMESTAMP DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX api_keys_user_id_idx ON api_keys (user_id);

-- ===================== Observable types =====================

-- Defines a kind of monitorable thing: `properties` are the input fields
-- used to create an `observables` row of this type, `observation_schema`
-- describes the fields recorded each time an Observable of this type is
-- observed, `observer_config_schema` describes which of those fields an
-- `observer_configs` row (see the "Observer configs" section below) must/
-- can supply extraction config for, and which are required, and
-- `observer_mechanism_schema` describes the observer-type-specific "how to
-- reach the source" fields an `observer_configs` row's `mechanism_config`
-- can/must supply (e.g. for web_scraper: urls_match, headers, ssl_verify -
-- see lib/observer_type_catalog.lua's header comment) - authored
-- explicitly here rather than hardcoded per observer type, so different
-- observable types can group/describe/require these fields differently.
-- Field NAMES in observer_config_schema/observer_mechanism_schema are only
-- meaningful because they match what the worker-side code that consumes
-- them expects by name (observation_schema property names / a given
-- observer type's own field vocabulary respectively) - the schema engine
-- itself doesn't know or enforce that.
-- Which observer implementation (see lib/observer_type_catalog.lua) reads
-- observer_config_schema/observer_mechanism_schema/observer_configs rows
-- for a given observable type is NOT itself configured here - exactly one
-- observer type (`web_scraper`) is implemented today, so every observable
-- type implicitly resolves to it (lib/observer_type_catalog.lua's
-- M.default()) rather than this being a stored, per-type choice. A second
-- real observer type would resolve that mapping in that one module, not by
-- reintroducing a column here.
-- The four schema columns are arrays of property-definition objects
-- ({name,label,description,group,type,multiple,required,searchable,
-- validations}), validated in Lua by server/lib/property_schema.lua, not
-- by a DB constraint - see docs/dev/observable-types-storage.md for the
-- full rationale (observable types are user-defined at runtime and this
-- repo has no migration system, so a fixed-column-per-type design would
-- need a schema migration for every new type).
CREATE TABLE observable_types (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL UNIQUE,
  label VARCHAR(255) DEFAULT NULL,
  description TEXT DEFAULT NULL,
  properties JSONB NOT NULL DEFAULT '[]'::jsonb,
  observation_schema JSONB NOT NULL DEFAULT '[]'::jsonb,
  observer_config_schema JSONB NOT NULL DEFAULT '[]'::jsonb,
  observer_mechanism_schema JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ===================== Observables =====================

CREATE TABLE observables (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  observable_type_id INTEGER NOT NULL REFERENCES observable_types(id) ON DELETE RESTRICT,
  -- Arbitrary per-type field values (e.g. {"url": "https://..."} for the
  -- seeded "product" type), validated in Lua against observable_types.properties
  -- for observable_type_id on every create/update (see
  -- plugins/entities/observables_routes.lua). The fixed `url` column this table
  -- used to have is gone - a "product" Observable's URL now lives at
  -- properties->>'url'.
  properties JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- Rolled up from this Observable's 'observe'-type jobs (see
  -- plugins/jobs/services/jobs.lua's _rollup) - type-agnostic, stays a
  -- fixed column. The FK to workers is added further down via ALTER
  -- TABLE, once that table exists. Nothing currently populates these four
  -- columns: observer.source = "queue" always reports its batch job with
  -- skip_rollup=true (its ref_id is a scheduler_tasks.id, not this
  -- observable's), and observer.source = "interval" no longer reports a
  -- per-observable job at all (see
  -- shared/watchtower_worker_core/processors.lua's process_observable) -
  -- kept only for schema/API compatibility.
  last_observe_status VARCHAR(255) DEFAULT NULL
    CHECK (last_observe_status IN ('pending', 'triggering', 'acknowledged', 'error')),
  last_observe_worker VARCHAR(255) DEFAULT NULL,
  last_observe_take_at TIMESTAMP DEFAULT NULL,
  last_observe_ack_at TIMESTAMP DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX observables_observable_type_id_idx ON observables (observable_type_id);
CREATE INDEX observables_properties_gin_idx ON observables USING GIN (properties jsonb_path_ops);

-- ===================== Rules =====================

CREATE TABLE rules (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  description TEXT DEFAULT NULL,
  source TEXT NOT NULL,
  condition_expression TEXT NOT NULL,
  -- Optional: overrides the matched alert's severity/tags - this IS the
  -- alert's severity (see plugins/rules/services/rule_engine.lua). Null
  -- means the alert keeps its default severity ("low") and no tags (see
  -- shared/analyzer.lua's derive_alert_fields).
  severity VARCHAR(10) DEFAULT NULL
    CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  tags VARCHAR(255)[] DEFAULT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  -- Optional anti-spam window: suppresses creating another alert for the
  -- same (rule, observable) pair within this many seconds of the last one (see
  -- shared/analyzer.lua's is_in_cooldown). Null/0 means no cooldown.
  cooldown_seconds INTEGER DEFAULT NULL CHECK (cooldown_seconds IS NULL OR cooldown_seconds >= 0),
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX rules_enabled_idx ON rules (enabled);

-- ===================== Alerts =====================

-- ===================== Workers (worker registry) =====================

CREATE TABLE workers (
  worker_id VARCHAR(255) PRIMARY KEY,
  connection_type VARCHAR(20) NOT NULL
    CHECK (connection_type IN ('http', 'mqtt', 'embedded')),
  version VARCHAR(255) DEFAULT NULL,
  capabilities VARCHAR(255)[] DEFAULT NULL,
  -- Self-reported, optional JSON blob describing the worker's configured
  -- sites/timing. The worker is responsible for omitting secrets before
  -- sending it - stored as opaque text, not parsed or enforced server-side.
  config TEXT DEFAULT NULL,
  uptime_seconds INTEGER DEFAULT NULL,
  -- Fixed, hardcoded roles this worker self-reports (a worker can have
  -- more than one at once, e.g. the embedded worker both observes and
  -- analyzes) - validated in Lua against the fixed set in
  -- plugins/workers/worker_role_schemas.lua, not a DB CHECK (Postgres
  -- can't constrain array element values without a trigger). `properties`
  -- holds role-specific self-reported metadata, validated against the
  -- concatenation of every declared role's property schema via
  -- lib/property_schema.lua - same JSONB pattern as observables/observations.
  roles VARCHAR(40)[] DEFAULT NULL,
  properties JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_seen_at TIMESTAMP NOT NULL DEFAULT NOW(),
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX workers_roles_gin_idx ON workers USING GIN (roles);

CREATE TABLE worker_heartbeats (
  id SERIAL PRIMARY KEY,
  -- Nullable (rather than NOT NULL) so deleting a worker row doesn't
  -- cascade into this history - matches observations.worker's own
  -- ON DELETE SET NULL precedent below.
  worker_id VARCHAR(255) DEFAULT NULL REFERENCES workers(worker_id) ON DELETE SET NULL,
  connection_type VARCHAR(20) NOT NULL
    CHECK (connection_type IN ('http', 'mqtt', 'embedded')),
  version VARCHAR(255) DEFAULT NULL,
  capabilities VARCHAR(255)[] DEFAULT NULL,
  uptime_seconds INTEGER DEFAULT NULL,
  -- `properties` is deliberately excluded here (same reason `config`
  -- already is) - avoid bloating this fast-growing append-only table with
  -- a field that changes/grows over time.
  roles VARCHAR(40)[] DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX worker_heartbeats_worker_id_idx ON worker_heartbeats (worker_id, created_at);

-- Deferred until here since observables is created before workers above.
ALTER TABLE observables
  ADD CONSTRAINT observables_last_observe_worker_fkey
  FOREIGN KEY (last_observe_worker) REFERENCES workers(worker_id) ON DELETE SET NULL;

-- Fired alerts, not a definition. A definition is a `rules` row; this table
-- holds one row per rule match against an ingested observation, created by
-- an "analyzer"-role worker (shared/analyzer.lua in the embedded worker,
-- POST /api/alerts from the standalone one's worker_rule_matcher.lua).
-- `observation_id`'s FK is
-- added further down via ALTER TABLE, once the `observations` table
-- exists (see the Observations section below).
CREATE TABLE alerts (
  id SERIAL PRIMARY KEY,
  severity VARCHAR(10) NOT NULL DEFAULT 'low'
    CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  severity_value SMALLINT NOT NULL GENERATED ALWAYS AS (
    CASE severity
      WHEN 'low' THEN 1
      WHEN 'medium' THEN 2
      WHEN 'high' THEN 3
      WHEN 'critical' THEN 4
    END
  ) STORED,
  observation_id INTEGER NOT NULL,
  rule_id INTEGER DEFAULT NULL REFERENCES rules(id) ON DELETE SET NULL,
  -- Null unless the matched rule declares its own `tags` - an observation
  -- carries no tags of its own to fall back to.
  tags VARCHAR(255)[] DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX alerts_severity_value_idx ON alerts (severity_value);
CREATE INDEX alerts_observation_id_idx ON alerts (observation_id);
CREATE INDEX alerts_created_at_idx ON alerts (created_at);
CREATE INDEX alerts_tags_idx ON alerts USING GIN (tags);
-- Enforces this table's own "one row per rule match against an ingested
-- observation" invariant (see the header comment above) - without this, an
-- "analyzer"-role worker re-analyzing an observable's still-latest,
-- unchanged observation (shared/analyzer.lua/worker_rule_matcher.lua) could
-- insert a genuine duplicate under a race. Postgres never treats two NULLs
-- as equal in a unique index, so this only constrains inserts made while
-- the matching rule still exists - rule_id only ever becomes NULL
-- afterward, via ON DELETE SET NULL above, never at creation time.
-- Its leading rule_id column also serves the rules(id) ON DELETE SET NULL
-- lookup and any "alerts for this rule" filter, so there is deliberately no
-- separate rule_id-only index.
CREATE UNIQUE INDEX alerts_rule_id_observation_id_idx ON alerts (rule_id, observation_id);
CREATE INDEX rules_tags_idx ON rules USING GIN (tags);

-- ===================== Jobs (worker work assignments) =====================

-- One row per work-assignment attempt on a (worker, type, ref_id) target.
-- Values are the verb form of the worker role that produces/will produce
-- them (see workers.roles below): type='observe' (ref_id -> observables.id,
-- produced by an "observer"-role worker) and type='observer_test' (ref_id ->
-- observer_config_test_requests.id, see the "Observer config test requests"
-- section below) are produced by the ordinary per-observable/per-request
-- paths. type='observe' is ALSO produced, one row per firing, by a
-- scheduler task (ref_id -> scheduler_tasks.id, from_scheduler=true - see
-- below); type='analyze', type='notify' and type='deliver' are exclusively
-- scheduler-fired this same way (there is no per-observable/per-alert path
-- for any of the three) - an "analyzer"-role worker re-runs rule matching
-- against each target Observable's latest observation, an "evaluator"-role
-- worker matches fired alerts against notification_policies and enqueues the
-- resulting (alert, channel) pairs onto alert_deliveries (type='notify'), and
-- a "deliver"-role worker claiming a type='deliver' job drains a batch of
-- those pending alert_deliveries rows and dispatches them through their
-- channel (see plugins/scheduler/services/scheduler.lua's claim_next_batch
-- and plugins/notification_channels/services/{notification_policy_engine,
-- delivery_queue}.lua). Claiming this job type is an alternative to the
-- deliver role's own independent alert_deliveries polling (see that table's
-- header comment) - which one a given worker uses is its own deliver.source
-- config, not a property of this table.
-- ref_id is deliberately not an FK (it's polymorphic across
-- observable/observer_config_test_request/scheduler_task depending on
-- type/from_scheduler) - application code is responsible for its integrity.
-- A given (worker,
-- type, ref_id) combination can have multiple rows over time - see
-- jobs_active_unique_idx below: only one may be 'triggering' (in flight) at
-- once, but a finished row (acknowledged/error) is permanent history, not
-- overwritten by the next attempt - see report()/report_error() in
-- plugins/jobs/services/jobs.lua.
CREATE TABLE jobs (
  id SERIAL PRIMARY KEY,
  -- NULL means either "queued, not yet claimed by a worker" (the only way a
  -- freshly-inserted row gets a NULL worker_id is
  -- plugins/scheduler/services/scheduler.lua's fire_due inserting a
  -- status='pending' row ahead of any worker claiming it - see
  -- :claim_next_job, which is what fills this in; every other report path,
  -- report()/report_error(), always supplies a worker_id) or "the worker
  -- that did this has since been deleted" (ON DELETE SET NULL below,
  -- matching observations.worker's own precedent - a job row is permanent
  -- history and shouldn't disappear just because its worker was removed
  -- from the registry).
  worker_id VARCHAR(255) DEFAULT NULL REFERENCES workers(worker_id) ON DELETE SET NULL,
  type VARCHAR(20) NOT NULL CHECK (type IN ('observe', 'analyze', 'notify', 'deliver', 'observer_test')),
  ref_id INTEGER NOT NULL,
  -- True for the single aggregate job a scheduler firing queues (see
  -- scheduler.lua's queue_pending_job) - ref_id is then a scheduler_tasks.id,
  -- never an observables.id. False for the ordinary per-observable
  -- type='observe'/type='observer_test' rows, where ref_id is an
  -- observables.id/observer_config_test_requests.id.
  -- This is what lets the UI (and GET /api/jobs' observable_type_id filter)
  -- resolve the otherwise-polymorphic ref_id unambiguously: type='observe'
  -- is the only type that's ever produced both ways, type='analyze'/
  -- 'notify' are always from_scheduler=true.
  from_scheduler BOOLEAN NOT NULL DEFAULT FALSE,
  -- 'error' is set by plugins/jobs/services/jobs.lua's report_error
  -- alongside error_at/message, and cleared by the worker's next report.
  status VARCHAR(255) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'triggering', 'acknowledged', 'error')),
  message TEXT DEFAULT NULL,
  action TEXT DEFAULT NULL,
  -- Arbitrary JSON payload a report can carry back alongside its
  -- status/action/message - only type='observer_test' populates this today
  -- (the {ok, data} scraped result from
  -- worker_plugins/watchtower_observer_web_scraper/scraper_creator.lua's
  -- WebScraper:run), but the column is generic for any future job type
  -- that needs more than a short message string.
  result JSONB DEFAULT NULL,
  retries INTEGER NOT NULL DEFAULT 0,
  taken_at TIMESTAMP DEFAULT NULL,
  acked_at TIMESTAMP DEFAULT NULL,
  error_at TIMESTAMP DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX jobs_worker_id_idx ON jobs (worker_id);
CREATE INDEX jobs_type_ref_id_idx ON jobs (type, ref_id);
CREATE INDEX jobs_status_idx ON jobs (status);

-- At most one unclaimed queued job per (type, ref_id) - so fire_due
-- re-firing a recurring cron task before the previous pending job has been
-- claimed reuses that same row instead of stacking a duplicate.
CREATE UNIQUE INDEX jobs_pending_unique_idx ON jobs (type, ref_id) WHERE status = 'pending';

-- At most one IN-FLIGHT job per (worker_id, type, ref_id) - this, not a
-- blanket forever-unique constraint, is the actual invariant that matters:
-- prevents two concurrent claims/reports racing on the same worker+target
-- while a job is actively being worked. Once a job reaches a terminal
-- status ('acknowledged'/'error') it's history and falls out of this
-- index, freeing that (worker_id, type, ref_id) slot for a genuinely new,
-- independent row - this is what lets a recurring scheduler task (see
-- plugins/scheduler/) produce one job row per firing instead of every
-- firing after the first colliding with the previous firing's now-finished
-- row (see report()/report_error()'s ON CONFLICT target in
-- plugins/jobs/services/jobs.lua, which targets this same partial index).
CREATE UNIQUE INDEX jobs_active_unique_idx ON jobs (worker_id, type, ref_id) WHERE status = 'triggering';

-- ===================== Scheduler (task definitions) =====================

-- Admin-configured task definitions the "scheduler" worker role evaluates
-- periodically (see server/plugins/scheduler/services/scheduler.lua's
-- fire_due, called from server/workers/observe_pending_worker.lua's embedded
-- tick and shared/watchtower_worker_core/provider_http.lua's standalone tick via
-- PUT /api/scheduler/fire-due) - deliberately decoupled from the
-- analyzer/observer/deliver role logic (see CLAUDE.md). `type` says what
-- KIND of work this task fires ('observe'/'analyze' target a set of observables;
-- 'notify' targets a notification-policy pass, see notify_policy_ids below)
-- and ON WHAT SCHEDULE (cron or one-shot) - firing itself does not do the
-- work directly, it queues one `jobs` row (status='pending', see above,
-- from_scheduler=true, ref_id=this row's id) per firing for a worker of the
-- matching role to claim. No separate run/audit table - `jobs` itself
-- (upserted in place per (worker_id, type, ref_id), same as every other job
-- type) is the only record of a firing's outcome.
CREATE TABLE scheduler_tasks (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  type VARCHAR(20) NOT NULL DEFAULT 'observe' CHECK (type IN ('observe', 'analyze', 'notify', 'deliver')),
  -- Required for 'observe'/'analyze' (an observable-scoped task); NULL for
  -- 'notify' (a notification-policy pass has no observable-type scope of
  -- its own - see notify_policy_ids below) and for 'deliver' (a delivery-queue
  -- drain pass has no observable scope either). Immutable after creation,
  -- same as `type` itself (see services/scheduler.lua's _derive).
  observable_type_id INTEGER REFERENCES observable_types(id) ON DELETE CASCADE,
  -- NULL/empty = wildcard: every enabled Observable of observable_type_id, resolved
  -- fresh at each firing (see services/scheduler.lua's
  -- _resolve_observable_ids). Non-empty = only these specific observable ids -
  -- validated in Lua on create/update that each id actually belongs to
  -- observable_type_id (no DB constraint possible on array-of-FK), and
  -- re-checked (still exists, still belongs to observable_type_id, still
  -- enabled) at firing time since an Observable can be deleted/retyped/disabled
  -- after this row is saved. Only meaningful for 'observe'/'analyze'.
  observable_ids INTEGER[] DEFAULT NULL,
  -- 'notify' only: NULL/empty = evaluate every enabled notification_policies
  -- row (the wildcard, same convention as observable_ids); non-empty = only these
  -- specific policy ids for this task's firings - validated in Lua that
  -- each id exists (see services/scheduler.lua's _derive). Not used by
  -- 'deliver' - a delivery-queue drain pass has no policy scope, it just
  -- claims whatever's already pending on alert_deliveries (policy matching
  -- already happened when those rows were enqueued by a 'notify' firing).
  notify_policy_ids INTEGER[] DEFAULT NULL,
  schedule_type VARCHAR(20) NOT NULL CHECK (schedule_type IN ('cron', 'one_shot')),
  -- Required (Lua-validated) when schedule_type='cron' - standard 5-field
  -- cron syntax (minute hour day-of-month month day-of-week), validated and
  -- evaluated by shared/watchtower_worker_core/cron.lua (hand-rolled, no new Luarocks dependency -
  -- same convention as shared/rule_engine/expr.lua/server/lib/zip_writer.lua).
  cron_expression VARCHAR(255) DEFAULT NULL,
  -- Required when schedule_type='one_shot'. NULL/omitted at creation means
  -- "run as soon as possible" - the server defaults it to NOW() (see
  -- services/scheduler.lua's _derive).
  run_at TIMESTAMP DEFAULT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  -- Computed server-side on create, and after each firing for cron tasks -
  -- this is what the scheduler's due-query filters on
  -- (WHERE enabled AND next_run_at <= NOW()). A one-shot task gets
  -- enabled=false (not a recomputed next_run_at) once it fires, so it
  -- naturally drops out of future due-queries without a separate "fired"
  -- flag.
  next_run_at TIMESTAMP DEFAULT NULL,
  last_run_at TIMESTAMP DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX scheduler_tasks_next_run_at_idx ON scheduler_tasks (next_run_at);
CREATE INDEX scheduler_tasks_observable_type_id_idx ON scheduler_tasks (observable_type_id);
CREATE INDEX scheduler_tasks_type_idx ON scheduler_tasks (type);

-- ===================== Observations (entity observation history) =====================

-- Was `monitoring` - renamed to free up "monitors" (now "workers") for the
-- worker registry above. Append-only observation log. Generalized
-- like `observables`: arbitrary per-type observation values (e.g. {"price":..,
-- "discount":.., "available":.., "url":..} for "product") live in
-- `properties`, validated in Lua against the owning Observable's observable_type's
-- observation_schema before insert (see
-- plugins/entities/observations_routes.lua) - the fixed
-- price/discount/available/url columns this table used to have are gone.
-- `worker` identifies which worker produced this observation (required
-- by POST /api/observations' request validation, though the column itself
-- stays nullable so deleting a worker row doesn't cascade into historical
-- data) - it's usable directly in rule definitions generically (see
-- plugins/rules/allowed_fields.lua's `worker` field), without leaking any
-- observable-type-specific field into the rule vocabulary.
CREATE TABLE observations (
  id SERIAL PRIMARY KEY,
  observable_id INT NOT NULL,
  FOREIGN KEY (observable_id) REFERENCES observables(id) ON DELETE CASCADE,
  properties JSONB NOT NULL DEFAULT '{}'::jsonb,
  worker VARCHAR(255) DEFAULT NULL REFERENCES workers(worker_id) ON DELETE SET NULL,
  timestamp TIMESTAMP NOT NULL
);

CREATE INDEX observations_properties_gin_idx ON observations USING GIN (properties jsonb_path_ops);
CREATE INDEX observations_worker_idx ON observations (worker);
-- Backs shared/analyzer.lua's fetch_baseline_properties (the "changed"/
-- "changed_within" rule operators' baseline lookup, see shared/rule_engine/expr.lua)
-- - a per-observable, most-recent-first history walk.
CREATE INDEX observations_observable_timestamp_idx ON observations (observable_id, timestamp DESC);

-- Deferred until here since alerts is created before observations above.
ALTER TABLE alerts
  ADD CONSTRAINT alerts_observation_id_fkey
  FOREIGN KEY (observation_id) REFERENCES observations(id) ON DELETE CASCADE;

-- ===================== Notification channels =====================

CREATE TABLE notification_channels (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  type VARCHAR(20) NOT NULL CHECK (type IN ('discord', 'webhook', 'email')),
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE notification_channels_discord (
  id SERIAL PRIMARY KEY,
  channel_id INT NOT NULL,
  FOREIGN KEY (channel_id) REFERENCES notification_channels(id) ON DELETE CASCADE,
  url VARCHAR(255) NOT NULL,
  message TEXT NOT NULL
);

CREATE TABLE notification_channels_webhook (
  id SERIAL PRIMARY KEY,
  channel_id INT NOT NULL,
  url VARCHAR(255) NOT NULL,
  method VARCHAR(10) NOT NULL CHECK (method IN ('GET', 'POST', 'PUT', 'DELETE', 'PATCH')),
  body TEXT NOT NULL,
  headers TEXT NOT NULL,
  FOREIGN KEY (channel_id) REFERENCES notification_channels(id) ON DELETE CASCADE
);

-- SMTP connection details (host/credentials) are a single app-wide setting
-- (SMTP_* env vars / WORKER_CONFIG_FILE - see shared/watchtower_worker_core/runner.lua's
-- resolve_smtp_password()), not stored here - this table only holds what's
-- genuinely per-channel: recipients and the message template.
CREATE TABLE notification_channels_email (
  id SERIAL PRIMARY KEY,
  channel_id INT NOT NULL,
  to_addresses TEXT NOT NULL, -- comma-separated recipients, same free-text
                               -- convention as notification_channels_webhook.headers
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  FOREIGN KEY (channel_id) REFERENCES notification_channels(id) ON DELETE CASCADE
);

-- Routes alerts to notification_channels - the same relationship `rules`
-- has to observations, mirrored for alerts (see
-- plugins/notification_channels/services/policies.lua and
-- .../notification_policy_engine.lua, and shared/rule_engine/expr.lua, reused
-- unchanged as the condition grammar). Authored the same way a rule is,
-- via a flat `source` document (name/if/channels/description/tags/enabled),
-- parsed by shared/rule_engine/source.lua (generic, not
-- rules-specific, so reused directly rather than duplicated). A scheduler
-- task of type='notify' evaluates every enabled policy (or a specific
-- subset, see scheduler_tasks.notify_policy_ids) against every currently
-- unnotified alert and dispatches to the union of matched channel_ids.
CREATE TABLE notification_policies (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  description TEXT DEFAULT NULL,
  source TEXT NOT NULL,
  condition_expression TEXT NOT NULL,
  channel_ids INTEGER[] NOT NULL,
  tags VARCHAR(255)[] DEFAULT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX notification_policies_enabled_idx ON notification_policies (enabled);

-- Per-(alert, channel) durable delivery queue for the notify pipeline.
-- Deliberately NOT columns on `alerts` itself - alerts records what fired,
-- this records whether/how it was delivered, so the alerting plugin/model
-- never needs to know the notify pipeline exists. Keyed per channel (not
-- one row per alert) because one alert can route to several channels via
-- several matched notification_policies, and a partial multi-channel
-- failure should only retry the channel(s) that actually failed.
--
-- This is a real claimable queue, not just an outcome log: the
-- "evaluator" worker role
-- (shared/watchtower_worker_core/notification_policy_matcher.lua, run
-- worker-side by both runtimes - never inside an API route) upserts a
-- 'pending' row per matched (alert, channel) pair; the "deliver" role drains this
-- queue one of two configurable ways (its own deliver.source config, not a
-- property of this table): by default, independently and continuously
-- claiming 'pending' rows directly
-- (plugins/notification_channels/services/delivery_queue.lua's claim_batch,
-- UPDATE ... WHERE status='pending' ... FOR UPDATE SKIP LOCKED, so multiple
-- senders could drain this concurrently), or via a scheduler_tasks
-- type='deliver' task, whose claim_next_batch branch calls that same
-- claim_batch internally and hands the result to whichever single worker
-- claimed the wrapping job. Either way, sending itself goes through
-- shared/watchtower_worker_core/notification_senders.lua. status
-- lifecycle: pending -> triggering (claimed by a sender) -> sent (terminal
-- success) | error (terminal for this attempt only - the evaluator's next
-- upsert resets an 'error' row back to 'pending' for retry, but leaves
-- 'sent'/'pending'/'triggering' rows alone).
CREATE TABLE alert_deliveries (
  alert_id INTEGER NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
  channel_id INTEGER NOT NULL REFERENCES notification_channels(id) ON DELETE CASCADE,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'triggering', 'sent', 'error')),
  -- ON DELETE SET NULL, matching observations.worker/jobs.worker_id's own
  -- precedent - a delivery's outcome is permanent history and shouldn't
  -- disappear (or block the worker's deletion outright) just because the
  -- worker that sent it was later removed from the registry.
  worker_id VARCHAR(255) DEFAULT NULL REFERENCES workers(worker_id) ON DELETE SET NULL,
  taken_at TIMESTAMP DEFAULT NULL,
  notified_at TIMESTAMP DEFAULT NULL,
  error_message TEXT DEFAULT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  PRIMARY KEY (alert_id, channel_id)
);

CREATE INDEX alert_deliveries_status_idx ON alert_deliveries (status);
-- The primary key's leading alert_id column serves that FK's cascade; this
-- serves notification_channels(id) ON DELETE CASCADE.
CREATE INDEX alert_deliveries_channel_id_idx ON alert_deliveries (channel_id);

-- ===================== Observer configs =====================

-- Generic observer-configuration registry, applicable to ANY observable_type
-- and (in the future) any observer_type, not just the implicit
-- "product"/web_scraper pairing. Many rows may share one
-- observable_type_id - each is one named "site" (or future observer_type's
-- equivalent unit), fed together into one worker-side observer instance
-- for that observable_type (see
-- shared/watchtower_worker_core/observer_registry.lua: at most one
-- OBSERVER INSTANCE per observable_type, but that instance wraps
-- arbitrarily many sites/units). There is deliberately no `observer_type`
-- column here: exactly one observer type (`web_scraper`) is implemented
-- today, resolved via lib/observer_type_catalog.lua's M.default() wherever
-- it's needed (see plugins/observer_configs/plugin.lua), not stored.
CREATE TABLE observer_configs (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  observable_type_id INTEGER NOT NULL REFERENCES observable_types(id) ON DELETE CASCADE,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  -- Field-extraction map: {selector: string[]} | {compute: string}
  -- (+ optional transform/validate/temporal), validated in Lua by
  -- server/lib/observer_field_schema.lua - against the required
  -- field-name list taken from observable_type_id's own
  -- observer_config_schema (authored on observable_types, see above), not
  -- a hardcoded price/discount/available list. The per-field shape
  -- (selector|compute) itself is owned by observer_type's catalog entry
  -- (server/lib/observer_type_catalog.lua) - only web_scraper exists
  -- today, so it's the only shape in practice.
  fields JSONB NOT NULL,
  -- Observer-type-specific "mechanism" config: everything about HOW to
  -- reach/validate the source that is NOT about which fields to extract -
  -- validated generically in Lua by lib/property_schema.lua's
  -- validate_values, against the observable type's own admin-authored
  -- observer_mechanism_schema (see the observable_types table comment
  -- above; that schema's "map" type is what makes an object value like
  -- {headers: {string:string}} expressible). A single JSONB blob, not a
  -- notification_channels-style bridge table per observer_type, so a
  -- future second observer type needs no ALTER TABLE - this repo has no
  -- migration system.
  mechanism_config JSONB NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX observer_configs_observable_type_id_idx ON observer_configs (observable_type_id);
CREATE INDEX observer_configs_enabled_idx ON observer_configs (enabled);

-- ===================== Observer config test requests =====================

-- Records an ad-hoc "test this observer config against a URL" request -
-- "record the request, let a worker claim it as a jobs row, run the
-- observe off the request cycle" pattern, keyed under type='observer_test'
-- (see jobs.type CHECK above).
CREATE TABLE observer_config_test_requests (
  id SERIAL PRIMARY KEY,
  -- {mode:"adhoc", observable_type_id, observer_type, name, fields,
  --  mechanism_config} | {mode:"saved", observer_config_id} |
  -- {mode:"all", observable_type_id, observer_type} - the observable_type_id
  -- discriminator "all" needs here is required since observer_configs spans
  -- many observable types. `observer_type` is always
  -- lib/observer_type_catalog.lua's M.default() (see
  -- plugins/observer_configs/plugin.lua), never client-supplied - stored
  -- here purely so the worker-side poller doesn't need its own extra
  -- lookup at execution time.
  config JSONB NOT NULL,
  test_url TEXT NOT NULL,
  requested_by INTEGER DEFAULT NULL REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ===================== Seed data =====================

-- No `users` rows are seeded here - the first admin account is created
-- idempotently at server boot from INITIAL_ADMIN_USERNAME/
-- INITIAL_ADMIN_PASSWORD env vars (see server/workers/bootstrap_admin.lua),
-- so a fresh DB with those unset simply has zero users until one is
-- created through the UI by an existing admin.
INSERT INTO roles (name, permissions) VALUES
  ('admin', ARRAY[
    'observables:read','observables:create','observables:update','observables:delete',
    'observations:read','observations:create','observations:delete',
    'observable_types:read','observable_types:create','observable_types:update','observable_types:delete',
    'alerts:read','alerts:create','alerts:update','alerts:delete',
    'rules:read','rules:create','rules:update','rules:delete',
    'scheduler:read','scheduler:create','scheduler:update','scheduler:delete',
    'workers:read','workers:write','workers:delete',
    'jobs:read','jobs:create','jobs:update','jobs:delete',
    'channels:read','channels:create','channels:update','channels:delete',
    'policies:read','policies:create','policies:update','policies:delete',
    'deliveries:read','deliveries:create','deliveries:update',
    'observer_configs:read','observer_configs:create','observer_configs:update','observer_configs:delete',
    'api_key:manage',
    'users:read','users:create','users:update','users:delete',
    'roles:read','roles:create','roles:update','roles:delete'
  ]),
  ('operator', ARRAY[
    'observables:read','observables:create','observables:update','observables:delete',
    'observations:read','observations:create','observations:delete',
    'observable_types:read',
    'alerts:read','alerts:create','alerts:update','alerts:delete',
    'rules:read','rules:create','rules:update','rules:delete',
    'scheduler:read','scheduler:create','scheduler:update','scheduler:delete',
    'workers:read',
    'jobs:read',
    'channels:read','channels:create','channels:update','channels:delete',
    'policies:read','policies:create','policies:update','policies:delete',
    'deliveries:read',
    'observer_configs:read','observer_configs:create','observer_configs:update','observer_configs:delete'
  ]),
  ('viewer', ARRAY[
    'observables:read','observations:read','observable_types:read','alerts:read',
    'rules:read','scheduler:read','workers:read','jobs:read','channels:read','policies:read',
    'deliveries:read','observer_configs:read'
  ]);
