# Description

Price monitor: define items to track, scraper site configs, notification channels, and rules for turning matched price changes into alerts — all managed through an authenticated API and a web UI. Monitors (an embedded worker inside the server, and/or standalone worker processes) scrape items on a schedule and ingest observations; a boolean-expression rule engine matches each ingested observation against the configured rules and fires alerts.

# Architecture

## Server

An OpenResty/Lapis API manages items, scraper site definitions, notification channels, rules, users/roles/API keys, and serves the frontend. Every route is authenticated and permission-gated (JWT login or API key; see `CLAUDE.md`'s "Users & roles" section).

Historical price observations are stored, each optionally producing a raw ingest `event` that the rule engine evaluates, producing `alerts`.

## Workers

A monitor is a scraping agent: it polls items, scrapes them against the configured site definitions, ingests an observation, and reports job status. It can run:

- **Embedded** — inside the server's own OpenResty worker process (`USE_EMBED_WORKER=1`), talking to the database directly.
- **Standalone** — a separate Lua process (`worker/lua/`) authenticating with an API key over HTTP.

Both share the same pipeline code (`shared/`).

Technologies:

- OpenResty / Lua / Lapis
- PostgreSQL
- Vue 3 (Vuetify for the original plugins, Pinia + Tailwind for the redesigned ones — see `CLAUDE.md`)

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
- Vue / Vuetify: https://vuetifyjs.com/en/components
- Pinia / Tailwind CSS
- A boolean-expression rule engine and a shared worker pipeline (embedded + standalone)

Enhance:

- Lua
