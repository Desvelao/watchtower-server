# Description

watchtower-server: define observables to track, scraper site configs, notification channels, and rules for turning matched price changes into alerts — all managed through an authenticated API and a web UI. Workers (an embedded worker inside the server, and/or standalone worker processes) observe observables on a schedule and ingest observations; a boolean-expression rule engine matches each ingested observation against the configured rules and fires alerts.

# Architecture

## Server

An OpenResty/Lapis API manages observables, scraper site definitions, notification channels, rules, users/roles/API keys, and serves the frontend. Every route is authenticated and permission-gated (JWT login or API key; see `CLAUDE.md`'s "Users & roles" section).

Historical price observations are stored, each optionally producing a raw ingest `event` that the rule engine evaluates, producing `alerts`.

## Workers

A worker polls observables, observes them against the configured site definitions, ingests an observation, reports job status, and self-registers/heartbeats into the server's worker registry (self-reporting one or more fixed roles — `analyzer`/`observer`/`deliver`/`scheduler`, see `CLAUDE.md`). It can run:

- **Embedded** — inside the server's own OpenResty worker process (`USE_EMBED_WORKER=1`), talking to the database directly.
- **Standalone** — a separate Lua process (`worker/lua/`) authenticating with an API key over HTTP.

Both share the same pipeline code (`shared/`). A `"scheduler"`-role worker periodically evaluates admin-configured task definitions (cron-recurring or one-shot — the "Scheduler" plugin) and generates observe work for `"observer"`-role workers to pick up ahead of the normal queue.

Technologies:

- OpenResty / Lua / Lapis
- PostgreSQL
- Vue 3, Pinia + Tailwind (see `CLAUDE.md`)

See `CLAUDE.md` for a full architecture map (plugin system, rule engine, worker pipeline, auth design) and `docker/worker/worker_config.example.lua` for the worker configuration reference.

# Development

```console
cd dev
docker compose up -d
```

See `dev/README.md` for the full dev workflow (live editing, running the standalone worker manually, connecting to the database, tests).

# Deploy

```console
cd prod
docker compose up -d
```

See `prod/.env.example` for the required environment variables (`JWT_SECRET`, `INITIAL_ADMIN_USERNAME`/`PASSWORD` for the first admin account, database credentials).

# Objectives

Learn about:

- OpenResty / Lapis
- PostgreSQL
- Scraping data
- Vue 3
- Pinia / Tailwind CSS
- A boolean-expression rule engine and a shared worker pipeline (embedded + standalone)

Enhance:

- Lua
