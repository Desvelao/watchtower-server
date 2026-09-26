-- Pinned third-party LuaRocks dependencies for the standalone worker images
-- (docker/images/dev/worker/Dockerfile, docker/images/prod/worker/Dockerfile).
-- Installed with `luarocks-5.1 install --only-deps <this file>` - see
-- docker/rockspecs/watchtower-server-deps-1.0-1.rockspec's header for why
-- this is a separate, no-op "package".
package = "watchtower-worker-deps"
version = "1.0-1"

source = {
  url = "git+https://github.com/Desvelao/watchtower-server",
}

description = {
  summary = "Pinned LuaRocks dependencies for the watchtower-server standalone worker Docker images.",
  homepage = "https://github.com/Desvelao/watchtower-server",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1, < 5.4",
  "lua-cjson == 2.1.0.10-1",
  -- luasec/luasocket: shared/watchtower_worker_core/notification_senders.lua's
  -- outbound webhook/Discord HTTP client, and pling's own LuaSocket/LuaSec-
  -- based module requires at load time - this plain Lua process (unlike the
  -- embedded worker's nginx worker process) can use them directly. Same rocks
  -- docker/rockspecs/watchtower-server-deps-1.0-1.rockspec pins for the
  -- OpenResty/Lapis server image.
  "luasec == 1.3.2-1",
  "luasocket == 3.1.0-1",
  "pling == 0.1.0-1",
}

build = {
  type = "none",
}
