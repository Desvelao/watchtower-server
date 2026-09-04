# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

price-monitor tracks the price/discount/availability of items across the web. A Lapis (Lua/OpenResty) HTTP API server manages items, scraper site definitions, notification channels, users/roles/API keys, and a boolean-expression rule engine, and serves the frontend. Monitors (an embedded worker inside the server, and/or standalone worker processes) scrape items on a schedule, ingest observations, and let the rule engine turn matching observations into alerts.

Git-initialized (`main` branch). No CI test job exists yet beyond the Docker image build (`.github/workflows/docker-publish.yml`); there is no Lua test suite, only a frontend vitest suite (see below).

## Development commands

All development happens through the dev Docker Compose stack; there is no local Lua toolchain expected on the host.

```console
cd dev
docker compose up -d              # server, db, frontend (worker is idle by default, see below)
docker compose stop
docker compose down -v            # also drops the db volume - needed after any schema change
```

- `server/` and `shared/` are bind-mounted into the `lapis` container for live editing — restart the container to pick up changes (`lua_code_cache` is off in dev, but `init_worker_by_lua_block` code — `bootstrap_admin.lua`, the embedded worker — only runs once at boot, so those specifically need a restart).
- The `worker` dev container mounts `worker/lua` and `shared/`, but its entrypoint is overridden to `tail -f /dev/null`; exec in and run `lua main.lua` manually while iterating (needs a real `SERVER_API_KEY` and a `WORKER_CONFIG_FILE` — see `docker/worker/worker_config.example.lua`).
- The `db` service auto-loads `config/dataset/init.sql` on first boot (Postgres `docker-entrypoint-initdb.d`). There is no migration system — changing the schema means editing that file and recreating the volume (`docker compose down -v`).
- The `frontend` service runs `yarn && yarn dev` on Node 22 (Tailwind 4's `@tailwindcss/oxide` needs >= 20; vitest 4's toolchain transitively needs >= 22).

Frontend tests (vitest; there is no Lua test suite):
```console
cd public && yarn install && yarn test
```

## Architecture

### Server (`server/`) — Lapis app on OpenResty

Entry point: `server/app.lua`, run via `lapis server development|production` (see `docker/images/{dev,prod}/*/Dockerfile`). Plugins register themselves through `lib/plugins-service.lua` (topologically sorted by `dependencies`, each plugin's `setup(app, deps)` return value handed to any plugin that declares it as a dependency — mirrored exactly, name for name, by the frontend's `public/src/core/services/plugin-service.js`). Registration order in `app.lua`: `security`, `rules`, `alerting`, `events`, `observations`, `monitors`, `jobs`, `notification_channels`, `items`, `scraper_remote_config_lua`.

- **`plugins/security/`** — users, roles, API keys, JWT + API-key auth, RBAC. `services/{auth,auth_jwt,auth_api_key,rbac,users,roles,store_api_key,rate_limit,password_hash,secure_compare}.lua`. `setup()` returns `{auth, rbac, rate_limit, users, roles, perms}`; every other plugin declares `dependencies = {'security'}` and wraps its routes in `compose(auth:with({require=true}), rbac:with(perms.X), ...)`. Enforcement is always a live DB read, never a token claim: `auth.lua` 401s on `user.enabled == false` on every request; `rbac.lua` resolves permissions via `roles:get_permissions(role_id)` (an `invalidate()`-on-mutation cache), never the JWT's own `role` claim; `auth_api_key.lua` re-intersects a key's stored permissions with its owner's *current* permissions on every use. `permissions.lua` is the fixed permission catalog (mirrored by hand in `public/src/constants/permissions.js` — keep both in sync). The first admin account is bootstrapped idempotently at server boot from `INITIAL_ADMIN_USERNAME`/`INITIAL_ADMIN_PASSWORD` by `server/workers/bootstrap_admin.lua`, required from `nginx.conf`'s `init_worker_by_lua_block` (not from `app.lua`'s top level — that module is `require`d fresh on every request in dev with `lua_code_cache off`, and real DB I/O inside a module body hits OpenResty's "attempt to yield across C-call boundary"; the actual insert runs inside an `ngx.timer.at(0, ...)` callback instead).
- **`plugins/rules/`** — the condition DSL. `services/rule_source.lua` parses a flat, YAML-*like* (deliberately not real YAML — see its header) rule document (`name`/`if`/`action`/`enabled`, optional `description`/`severity`/`tags`); `if` is a boolean expression evaluated by `shared/rule_expr.lua` (hand-rolled recursive-descent parser + evaluator) over the fields declared in `allowed_fields.lua` — `tags` (`has`), `source`, `item`, `item_id`, `price`, `discount`, `available`, `url`, and `payload.*`. `services/rule_engine.lua` finds every enabled rule (cached, `invalidate()`d on any rule mutation) matching a given context and returns one `{id, action, severity, tags}` per match. `POST /api/rules/test`/`test-expression` expose this read-only.
- **`plugins/events/`** — `POST /api/events` is the *sole* entry point that creates a fired alert: its `on_create` hook builds a rule-matching context from the event (source/tags/payload, plus price/discount/available/url lifted from the event's JSON payload) and creates one `alerts` row per rule match via the alerting plugin's `alert_manager` (or a single fallback row with a null `rule_id`/`pattern` when nothing matches).
- **`plugins/alerting/`** — read + delete only over *fired* alert instances (status/priority state machine: `inactive|pending|triggering|acknowledged|error`). No POST/PUT of alert content. Status-mutation routes (`PUT /api/alerts/:id/:status`, `/ack`, `/error`) are deliberately not implemented yet — there is no notification worker to drive them (see `jobs.type` below); a fired alert's `status`/`monitor`/`*_at` columns stay at their defaults until one exists.
- **`plugins/observations/`** — price observation ingest/history (was `monitoring`/`/api/monitors`, renamed to free `monitors` for the registry below). `POST /api/observations` also creates a linked `event` (source = item name, payload = the observation JSON) so every ingested price runs through the rule engine.
- **`plugins/monitors/`** — the scraping-agent registry monitors self-register/heartbeat into (`PUT /api/monitors/:id/heartbeat`), plus bucketed heartbeat history (`GET /api/monitors/:id/heartbeats`) for a connectivity histogram.
- **`plugins/jobs/`** — one row per `(monitor_id, type, ref_id)` work assignment; only `type='scrape'` (`ref_id` → `items.id`) is produced today, `type='notify'` is reserved for a future notification worker (targeting `alerts`) without another schema change. `services/jobs.lua`'s `report`/`report_error`/`_rollup` upsert-and-roll-up logic: `retries` increments only on a same-status re-report (never on forward progress), an already-`acknowledged` job is never downgraded by a later error, and the rollup ranks `acknowledged > triggering > error > pending`. The rollup target is per-type (`{manager, apply}` in `jobs/plugin.lua`) — `type='scrape'` writes `items.last_scrape_status`/`last_scrape_monitor`/`last_scrape_take_at`/`last_scrape_ack_at`.
- **`plugins/{items,notification_channels,scraper_remote_config_lua}/`** — mostly unchanged from before the redesign (gated behind `security` in Phase 2), see their own files. `scraper_remote_config_lua`'s `/test*` routes use `shared/scraper_creator.lua` rather than registering a `WebScraper` inline.
- **`lib/`** — `plugins-service.lua` (the loader above), `routes.lua` (`compose`, `with_error_handling`, `capture_bad_request_params_validate`, `get_db_query_params_from_request_params`/`get_db_where_clause_from_request_params` — sort keys and search values are safely escaped, not interpolated raw — `pick_params`, `resolve_relative_date`, `with_transaction`), `resource_manager.lua` (generic CRUD/search manager most plugins build on), `models.lua` (`enhance_bridge_model`/`decorate_methods` for polymorphic bridge/subtype models, e.g. `notification_channels`).

### Shared pipeline (`shared/`) — used by both the standalone Lua worker and the embedded server worker

`worker_runner.lua`'s `build_config(mode)` is the single place `WORKER_CONFIG_FILE` (a `.lua` file, resolved through `config_provider.lua`/`config_provider_file.lua`) is loaded from. The server API key has its own precedence chain (`SERVER_API_KEY_FILE` → `SERVER_API_KEY` → `server.api_key` in the config file — most-secure-first; the file variant is how Docker/Compose secrets integrate with no extra code). `worker_pipeline.lua` builds a declarative `inputs → filters → outputs` config (via `luastash`): `filter_processing` (report `triggering`) → `filter_scrape` (run `scraper_creator.lua`'s `WebScraper` against the item's URL; coerces the extracted price to a real number — WebScraper's fields are always strings) → `filter_ack` (post the observation, report `acknowledged`), with `filter_drop` short-circuiting the chain on error **by calling `utils.end_pipeline()`** — merely returning `nil` from a filter does *not* stop pipeflow's step loop, it just passes `nil` into the next step, which was a real, easy-to-reintroduce bug caught during this port's own verification.

The embedded worker (`server/workers/scrape_pending_worker.lua`, `USE_EMBED_WORKER=1`) polls items directly in-process (no HTTP) and registers itself before its first job report (`jobs.monitor_id` has an FK to `monitors`). Its scraper (site list from `scraper_remote_sites`, a real DB query) is built **inside** the `ngx.timer.at(0, ...)` registration callback, not at module top level — same "attempt to yield across C-call boundary" trap `bootstrap_admin.lua` avoids; a bare `pcall` around a top-level DB call silently swallows that error and leaves the worker with zero registered sites forever, which is exactly what happened during this port's own verification before the fix.

The standalone worker (`worker/lua/main.lua` + `provider_http.lua`) polls `GET /api/items` over HTTP with an API key, scrapes, `POST`s `/api/observations`, and reports via `PUT /api/jobs/scrape/:id/{triggering,ack,error}`.

### Frontend (`public/`) — Vue 3, Vuetify **and** Pinia+Tailwind coexisting

The pre-existing plugins (`items`, `notification_channels`, `scrapers`, `observations`) stay on Vuetify with no state library, driven by `public/src/core/services/plugin-service.js`. The redesign's new plugins (`security`, `rules`, `events`, `alerting`, `monitors`, `jobs`) are Pinia + Tailwind, following pibuzz's frontend conventions: `stores/createListStore.js` is the shared server-side search/filter/sort/paginate factory every list store is built on; `components/common/DataTable.vue` + `TableFilterBar.vue` is the shell every list view composes; `core/router.js`'s single `beforeEach` guard reads `to.meta.permission`/`.public` (set by `core/services/app-service.js`'s `registerApp`) against the `auth` Pinia store — a route with neither (every pre-existing Vuetify route) stays open to any authenticated user. `main.js` awaits `useAuthStore().restore()` before mounting so the guard never sees an unhydrated store. `core/Layout.vue` filters the nav rail the same way.

**New views should be built from `components/common/` pieces wherever the feature fits an existing component's shape** — any new list/table view should use `DataTable` + `TableFilterBar`, matching how `RulesListView`/`EventsListView`/`AlertsListView`/`UsersListView`/`RolesListView`/`ApiKeysView`/`JobsListView` already do.

Domain components shared across more than one plugin (`AlertStatusBadge`, `AlertPriorityBadge`, `AlertDetailsFlyout`, `MonitorConfigFlyout`) live at the top level of `components/`, not nested inside one plugin's own `views/` — both `alerting` and `jobs`/`monitors` reference them.

### Users & roles, rule engine

Same live-enforcement design as pibuzz's — see `plugins/security/`'s section above. No user or role is hardcoded; `users`/`roles` are real Postgres tables seeded only with the three default roles (`admin`/`operator`/`viewer`), never any user rows.

### `docker/` layout

- `docker/images/dev/lapis/` — dev OpenResty+Lapis image (`entrypoint.sh` runs every plugin's `setup.sh`, e.g. the scraper plugin's `webscraper`/`xml` install fix).
- `docker/images/dev/worker/` — standalone worker image: Lua 5.1 + LuaRocks built from source on Alpine (no OpenResty needed), reusing the scraper plugin's `setup.sh`/`xml.rockspec` fix for `webscraper`, plus `lua-cjson`/`luasec`/`luasocket`/`luastash`.
- `docker/images/prod/server/` — two-stage build: Node 22 frontend build, then the same OpenResty+Lapis image as dev (`production` mode).
- `docker/worker/worker_config.example.lua` — the full `WORKER_CONFIG_FILE` reference.
