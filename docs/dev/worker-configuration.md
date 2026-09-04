# Worker configuration

Both the embedded worker (`server/workers/scrape_pending_worker.lua`,
`USE_EMBED_WORKER=1`) and the standalone worker (`worker/lua/main.lua`) build
their runtime config the same way: `shared/worker_runner.lua`'s
`build_config(mode)` loads `WORKER_CONFIG_FILE` (a plain `.lua` file that
returns a table) via `shared/config_provider.lua`/`config_provider_file.lua`,
then layers env vars and mode-specific defaults on top. A missing/unreadable
`WORKER_CONFIG_FILE` is not an error — every field just falls back to its
default (or, for `server`/`sites`, is simply absent).

See `docker/worker/worker_config.example.lua` for a fully-commented example
covering every field below. Copy it to `outputs/worker_config.lua` (gitignored
— see `.gitignore`) and point `WORKER_CONFIG_FILE` at it; the dev compose
stack already defaults `WORKER_CONFIG_FILE` to
`/etc/price-monitor/outputs/worker_config.lua` with `../outputs` bind-mounted
into both the `lapis` and `worker` services at that path.

## Fields

| Field | Default | Applies to | Notes |
|---|---|---|---|
| `version` | `"dev"` | both | Self-reported in heartbeats. |
| `poll_interval` | `10` (embedded) / `5` (standalone) | both | Seconds between scrape attempts. |
| `heartbeat_interval` | `30` | both | Seconds between monitor heartbeats. |
| `item_filter` | — | both | Self-reported in heartbeats, informational only (query-param-shaped, e.g. `"enabled=true"` — not parsed or enforced server-side). |
| `report_config` | `false` | both | Opt-in: self-report a secret-scrubbed copy of this config in every heartbeat (see `shared/worker_config_report.lua`'s allow-list). |
| `sites` | — | standalone only | Array of `{name, urls_match, fields, urls_test}` — same shape as `POST /api/scrapers/remote_config_lua/site`'s body. The embedded worker ignores this: it queries `scraper_remote_sites` directly (already in-process). |
| `server.address` | — | standalone only | Base URL of the price-monitor server, e.g. `http://lapis:8080`. |
| `server.batch_size` | `10` | standalone only | Items fetched per `GET /api/items` page. |
| `server.monitor_id` | `"worker-lua"` | standalone only | The monitor's registered identity. |
| `server.api_key` | — | standalone only | Least-secure of the three ways to supply the key (see below) — only reasonable in a gitignored, tightly-permissioned file. |

The embedded worker ignores `server`/`sites` entirely — it talks to the
database directly, not over the HTTP API, and reads scraper sites from
`scraper_remote_sites`.

## The server API key (standalone only)

Resolved by `resolve_server_api_key()` in `shared/worker_runner.lua`,
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
`outputs/worker_config.lua`/a `SERVER_API_KEY_FILE`).

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

Neither worker enforces a scrape cooldown yet — the embedded worker's
`get_pending_item()` always re-selects the single "stalest" enabled item
(never-scraped first, then whichever was scraped longest ago), and the
standalone worker's `_fetch_item_batch()` just re-paginates through every
enabled item each full pass. With one or a handful of items this means
continuous scraping at `poll_interval` cadence; a real per-item cooldown
(skip items scraped within the last N seconds) is a natural follow-up once
there's more than a handful.
