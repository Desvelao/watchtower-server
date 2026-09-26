-- Pinned third-party LuaRocks dependencies for the OpenResty/Lapis server
-- images (docker/images/dev/lapis/Dockerfile, docker/images/prod/server/Dockerfile).
-- Installed with `luarocks-5.1 install --only-deps <this file>` - nothing
-- about this rockspec itself (package/version/source) is ever built or
-- fetched, only its `dependencies` table is resolved, each pinned to an
-- exact version so a rebuild can't silently pick up a newer/breaking rock.
package = "watchtower-server-deps"
version = "1.0-1"

source = {
  url = "git+https://github.com/Desvelao/watchtower-server",
}

description = {
  summary = "Pinned LuaRocks dependencies for the watchtower-server OpenResty/Lapis Docker images.",
  homepage = "https://github.com/Desvelao/watchtower-server",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1, < 5.4",
  "lapis == 1.19.0-1",
  "tableshape == 2.7.0-1",
  -- lua-resty-jwt pulls in resty.openssl.kdf as a transitive dependency,
  -- which server/plugins/security/services/password_hash.lua needs for
  -- scrypt - no separate package required for that.
  "lua-resty-jwt == 0.3.2-1",
  -- luasec/luasocket: shared/watchtower_worker_core/notification_senders.lua's
  -- outbound webhook/Discord HTTP client (socket.http/ssl.https/ltn12) - same
  -- rocks docker/rockspecs/watchtower-worker-deps-1.0-1.rockspec pins for the
  -- standalone worker image, for the same reason. These only work for the
  -- standalone worker's plain Lua process though - LuaSocket/LuaSec cannot
  -- run inside an nginx worker process (ngx_lua breaks LuaSocket's real,
  -- blocking socket.tcp() there by design), so the embedded worker's
  -- "deliver" role tick uses server/lib/resty_webhook_transport.lua
  -- (lua-resty-http, a pure Lua cosocket-based client) instead - both rocks
  -- are still installed here since this same Lua tree also has to satisfy
  -- pling's own (LuaSocket/LuaSec-based) module requires at load time.
  "luasec == 1.3.2-1",
  "luasocket == 3.1.0-1",
  "lua-resty-http == 0.18.0-0",
  -- lua-resty-mail: same cosocket rationale, but for outbound SMTP instead of
  -- HTTP - pling.notifiers.email's own LuaSocket socket.smtp/socket.tp/mime
  -- protocol code cannot run inside an nginx worker process either (see
  -- server/lib/resty_mail_notifier.lua's header comment), so the embedded
  -- worker's "deliver" role sends email through this pure cosocket SMTP
  -- client instead.
  "lua-resty-mail == 1.2.0-1",
  "pling == 0.1.0-1",
}

build = {
  type = "none",
}
