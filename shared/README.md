# shared/

Lua modules used by both the server (`server/`) and the standalone worker
(`worker/lua/`). Mirrors `pibuzz/src/shared/`.

Loaded via `lua_package_path`/`LUA_PATH` pointing at this directory (see
`server/nginx.conf` and `dev/docker-compose.yml`), so anything here is
`require`d with a bare module name (e.g. `require("rule_expr")`), never
`require("shared.rule_expr")`.
