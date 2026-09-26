# shared/

Lua modules used by both the server (`server/`) and the standalone worker
(`worker/lua/`).

Loaded via `lua_package_path`/`LUA_PATH` pointing at this directory (see
`server/nginx.conf` and `dev/docker-compose.yml`), so anything here is
`require`d with a bare module name (e.g. `require("analyzer")`), never
`require("shared.analyzer")`.

`rule_engine/`, `watchtower_worker_core/`, and
`watchtower_observer_web_scraper/` are the three exceptions to "flat
module per file" here: each is a standalone,
independently-versioned/publishable LuaRocks package - `rule_engine/` for
boolean-expression rule matching (see `rule_engine/README.md`),
`watchtower_worker_core/` for the dependency-injected worker runtime
(config loading, the per-role task loop, observer-type routing,
and one poller per worker role - see `watchtower_worker_core/README.md`),
`watchtower_observer_web_scraper/` for the "web_scraper" observer-type
implementation that plugs into `watchtower_worker_core`'s
`observer_registry` (see `watchtower_observer_web_scraper/README.md`) -
kept inside this directory purely so local dev gets each on `LUA_PATH` for
free via the same mount as everything else; a real external consumer
installs via `luarocks install lua-rule-engine`/`watchtower-worker-core`/
`watchtower-observer-web-scraper` instead. All three are `require`d with
their own namespaced module names (`require("rule_engine.expr")`,
`require("watchtower_worker_core.runner")`,
`require("watchtower_observer_web_scraper")`, etc.), not a bare one,
since that's the name the published rock itself installs under.
