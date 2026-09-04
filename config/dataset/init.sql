-- price-monitor schema. Applied by Postgres' docker-entrypoint-initdb.d on
-- first boot only - there is no migration system (matches pibuzz's own
-- practice). Changing this file requires recreating the volume:
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
  -- A real FK to users.id, unlike pibuzz's bare `username VARCHAR` (which
  -- silently orphans a user's keys on rename) - deleting a user deletes
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

-- ===================== Items =====================

CREATE TABLE items (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  url TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ===================== Rules =====================

CREATE TABLE rules (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  description TEXT DEFAULT NULL,
  source TEXT NOT NULL,
  condition_expression TEXT NOT NULL,
  action VARCHAR(255) NOT NULL,
  -- Optional: overrides the matched alert's priority/tags - this IS the
  -- alert's severity (see plugins/rules/services/rule_engine.lua). Null
  -- means "leave the event's value as-is".
  severity VARCHAR(10) DEFAULT NULL
    CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  tags VARCHAR(255)[] DEFAULT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX rules_enabled_idx ON rules (enabled);

-- ===================== Events, alerts =====================

-- Raw ingested scrape results. The sole entry point for getting an alert
-- into the system - creating an event resolves a rule match and creates
-- the linked `alerts` row(s) as a side effect (see
-- plugins/events/plugin.lua's on_create hook). Events carry no priority of
-- their own - an alert's priority always comes from the matched rule's
-- `severity` override, or a hardcoded default when none applies.
CREATE TABLE events (
  id SERIAL PRIMARY KEY,
  source VARCHAR(255) DEFAULT NULL,
  payload TEXT DEFAULT NULL,
  tags VARCHAR(255)[] DEFAULT NULL,
  item_id INTEGER REFERENCES items(id) ON DELETE CASCADE,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX events_item_id_idx ON events (item_id);

-- ===================== Monitors (scraping agents) =====================

CREATE TABLE monitors (
  monitor_id VARCHAR(255) PRIMARY KEY,
  connection_type VARCHAR(20) NOT NULL
    CHECK (connection_type IN ('http', 'mqtt', 'embedded')),
  version VARCHAR(255) DEFAULT NULL,
  capabilities VARCHAR(255)[] DEFAULT NULL,
  -- Self-reported, query-param-shaped filter of what this monitor scrapes
  -- (e.g. "enabled=true"). Informational only - not parsed or enforced
  -- server-side.
  item_filter TEXT DEFAULT NULL,
  -- Self-reported, optional JSON blob describing the worker's configured
  -- sites/timing. The worker is responsible for omitting secrets before
  -- sending it - stored as opaque text, not parsed or enforced server-side.
  config TEXT DEFAULT NULL,
  uptime_seconds INTEGER DEFAULT NULL,
  last_seen_at TIMESTAMP NOT NULL DEFAULT NOW(),
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE monitor_heartbeats (
  id SERIAL PRIMARY KEY,
  monitor_id VARCHAR(255) NOT NULL REFERENCES monitors(monitor_id) ON DELETE CASCADE,
  connection_type VARCHAR(20) NOT NULL
    CHECK (connection_type IN ('http', 'mqtt', 'embedded')),
  version VARCHAR(255) DEFAULT NULL,
  capabilities VARCHAR(255)[] DEFAULT NULL,
  item_filter TEXT DEFAULT NULL,
  uptime_seconds INTEGER DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX monitor_heartbeats_monitor_id_idx ON monitor_heartbeats (monitor_id, created_at);

-- Fired alerts - a status/priority state machine, not a definition. A
-- definition is a `rules` row; this table holds one row per rule match
-- against an event (see plugins/events/plugin.lua).
CREATE TABLE alerts (
  id SERIAL PRIMARY KEY,
  -- 'error' is rolled up from a job whose dispatch failed (see
  -- plugins/jobs/services/jobs.lua's _rollup).
  status VARCHAR(255) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('inactive', 'pending', 'triggering', 'acknowledged', 'error')),
  priority VARCHAR(10) NOT NULL DEFAULT 'low'
    CHECK (priority IN ('low', 'medium', 'high', 'critical')),
  priority_value SMALLINT NOT NULL GENERATED ALWAYS AS (
    CASE priority
      WHEN 'low' THEN 1
      WHEN 'medium' THEN 2
      WHEN 'high' THEN 3
      WHEN 'critical' THEN 4
    END
  ) STORED,
  event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  -- Dispatch action resolved by the RuleEngine from the matching rule's
  -- `action`. Never client-supplied.
  pattern VARCHAR(255) DEFAULT NULL,
  rule_id INTEGER DEFAULT NULL REFERENCES rules(id) ON DELETE SET NULL,
  -- Copied from the linked event at creation, unless the matched rule
  -- declares its own `tags` (rule wins).
  tags VARCHAR(255)[] DEFAULT NULL,
  monitor VARCHAR(255) DEFAULT NULL REFERENCES monitors(monitor_id) ON DELETE SET NULL,
  monitor_take_at TIMESTAMP DEFAULT NULL,
  monitor_ack_at TIMESTAMP DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX alerts_status_idx ON alerts (status);
CREATE INDEX alerts_priority_value_idx ON alerts (priority_value);
CREATE INDEX alerts_rule_id_idx ON alerts (rule_id);
CREATE INDEX alerts_event_id_idx ON alerts (event_id);
CREATE INDEX alerts_created_at_idx ON alerts (created_at);
CREATE INDEX alerts_tags_idx ON alerts USING GIN (tags);
CREATE INDEX events_created_at_idx ON events (created_at);
CREATE INDEX events_tags_idx ON events USING GIN (tags);
CREATE INDEX rules_tags_idx ON rules USING GIN (tags);

-- ===================== Jobs (monitor work assignments) =====================

-- One row per (monitor, type, ref_id) work assignment - today only
-- type='scrape' (ref_id -> items.id) is produced; type='notify'
-- (ref_id -> alerts.id) is reserved for a future notification worker so
-- this table doesn't need a schema change to add it. ref_id is
-- deliberately not an FK (it's polymorphic across item/alert depending on
-- type) - application code is responsible for its integrity.
CREATE TABLE jobs (
  id SERIAL PRIMARY KEY,
  monitor_id VARCHAR(255) NOT NULL REFERENCES monitors(monitor_id) ON DELETE CASCADE,
  type VARCHAR(20) NOT NULL CHECK (type IN ('scrape', 'notify')),
  ref_id INTEGER NOT NULL,
  -- 'error' is set by plugins/jobs/services/jobs.lua's report_error
  -- alongside error_at/message, and cleared by the monitor's next report.
  status VARCHAR(255) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'triggering', 'acknowledged', 'error')),
  message TEXT DEFAULT NULL,
  action TEXT DEFAULT NULL,
  retries INTEGER NOT NULL DEFAULT 0,
  taken_at TIMESTAMP DEFAULT NULL,
  acked_at TIMESTAMP DEFAULT NULL,
  error_at TIMESTAMP DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  UNIQUE (monitor_id, type, ref_id)
);

CREATE INDEX jobs_monitor_id_idx ON jobs (monitor_id);
CREATE INDEX jobs_type_ref_id_idx ON jobs (type, ref_id);
CREATE INDEX jobs_status_idx ON jobs (status);

-- ===================== Observations (price history) =====================

-- Was `monitoring` - renamed to free up "monitors" for the scraping-agent
-- registry above. Append-only price observation log, unchanged shape.
CREATE TABLE observations (
  id SERIAL PRIMARY KEY,
  item_id INT NOT NULL,
  FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE,
  price NUMERIC(10,2) NOT NULL,
  url TEXT NOT NULL,
  timestamp TIMESTAMP NOT NULL,
  discount VARCHAR(255),
  available BOOLEAN
);

-- ===================== Notification channels =====================

CREATE TABLE notification_channels (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  type VARCHAR(20) CHECK (type IN ('discord', 'webhook')),
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

-- ===================== Scraper site definitions =====================

CREATE TABLE scraper_remote_sites (
  id                        SERIAL PRIMARY KEY,
  name                      TEXT   NOT NULL,
  urls_match                TEXT[] NOT NULL,
  fields_price_selector      TEXT[] NOT NULL,
  fields_price_transform     TEXT   ,
  fields_price_validate      TEXT   ,
  fields_discount_selector      TEXT[] NOT NULL,
  fields_discount_transform     TEXT   ,
  fields_discount_validate      TEXT   ,
  fields_available_selector      TEXT[] NOT NULL,
  fields_available_transform     TEXT   ,
  fields_available_validate      TEXT   ,
  urls_test                     TEXT[],
  created_at                TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ===================== Seed data =====================

-- No `users` rows are seeded here - the first admin account is created
-- idempotently at server boot from INITIAL_ADMIN_USERNAME/
-- INITIAL_ADMIN_PASSWORD env vars (see server/workers/bootstrap_admin.lua),
-- so a fresh DB with those unset simply has zero users until one is
-- created through the UI by an existing admin.
INSERT INTO roles (name, permissions) VALUES
  ('admin', ARRAY[
    'items:read','items:create','items:update','items:delete',
    'observations:read','observations:create','observations:delete',
    'events:read','events:create','events:delete',
    'alerts:read','alerts:update','alerts:delete',
    'rules:read','rules:create','rules:update','rules:delete',
    'monitors:read','monitors:write',
    'jobs:read',
    'channels:read','channels:create','channels:update','channels:delete',
    'scrapers:read','scrapers:write',
    'api_key:manage',
    'users:read','users:create','users:update','users:delete',
    'roles:read','roles:create','roles:update','roles:delete'
  ]),
  ('operator', ARRAY[
    'items:read','items:create','items:update','items:delete',
    'observations:read','observations:create','observations:delete',
    'events:read','events:create','events:delete',
    'alerts:read','alerts:update','alerts:delete',
    'rules:read','rules:create','rules:update','rules:delete',
    'monitors:read',
    'jobs:read',
    'channels:read','channels:create','channels:update','channels:delete',
    'scrapers:read','scrapers:write'
  ]),
  ('viewer', ARRAY[
    'items:read','observations:read','events:read','alerts:read',
    'rules:read','monitors:read','jobs:read','channels:read','scrapers:read'
  ]);
