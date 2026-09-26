# Standalone observe worker: Lua 5.1 + LuaRocks built from source on
# Alpine (no OpenResty needed - this is a plain Lua process, not an nginx
# worker). Same system/Lua/LuaRocks setup as docker/images/dev/worker/Dockerfile,
# but the app is baked in here (COPY) instead of bind-mounted, mirroring how
# docker/images/prod/server/Dockerfile relates to docker/images/dev/lapis/Dockerfile.
# Build context is the repo root (see dev/docker-compose.yml's worker
# service and docker/images/prod/server/README.md) so this can reuse the
# observer_configs plugin's xml-dependency fix (see
# server/plugins/observer_configs/{setup.sh,xml.rockspec}) instead
# of duplicating it.
FROM alpine:3.20

ENV LUA_VERSION=5.1.5
ENV LUAROCKS_VERSION=3.9.2

RUN set -ex \
    && apk -U upgrade \
    && apk add --no-cache readline \
    && apk add --no-cache --virtual .build-deps \
        ca-certificates openssl make gcc libc-dev readline-dev ncurses-dev \
    && wget --no-check-certificate -c \
        https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz -O lua.tar.gz \
    && echo "b3882111ad02ecc6b972f8c1241647905cb2e3fc  lua.tar.gz" | sha1sum -c -s - \
    && tar xzf lua.tar.gz \
    && cd lua-${LUA_VERSION} \
    && make -j"$(nproc)" linux \
    && make install \
    && cd .. \
    && rm -rf lua.tar.gz lua-${LUA_VERSION} \
    && apk del .build-deps \
    && apk add --no-cache ca-certificates openssl wget \
    && apk add --no-cache --virtual .build-deps make gcc libc-dev \
    && wget https://luarocks.github.io/luarocks/releases/luarocks-${LUAROCKS_VERSION}.tar.gz -O - | tar -xzf - \
    && cd luarocks-${LUAROCKS_VERSION} \
    && ./configure --with-lua=/usr/local \
    && make build \
    && make install \
    && cd .. \
    && rm -rf luarocks-${LUAROCKS_VERSION} \
    && apk add gcc musl-dev build-base openssl-dev git zlib-dev \
    && apk del .build-deps \
    # This from-source build installs a plain `luarocks` binary, not the
    # `luarocks-5.1` name the observer_configs plugin's setup.sh assumes (that
    # name only exists on the OpenResty image's Alpine-packaged luarocks,
    # see docker/images/dev/lapis/Dockerfile) - symlink so the same
    # unmodified script works here too.
    && ln -s "$(command -v luarocks)" /usr/local/bin/luarocks-5.1

# webscraper's xml dependency needs a patched rockspec - see
# server/plugins/observer_configs/setup.sh's header comment for
# why (upstream's rockspec doesn't build cleanly under luarocks 3.x).
COPY server/plugins/observer_configs/setup.sh /tmp/scraper-setup/setup.sh
COPY server/plugins/observer_configs/xml.rockspec /tmp/scraper-setup/xml.rockspec
RUN cd /tmp/scraper-setup && sh setup.sh && cd / && rm -rf /tmp/scraper-setup

# Pinned dependency versions - see
# docker/rockspecs/watchtower-worker-deps-1.0-1.rockspec for the exact list
# and per-rock rationale.
COPY docker/rockspecs/watchtower-worker-deps-1.0-1.rockspec /tmp/watchtower-worker-deps-1.0-1.rockspec
RUN luarocks-5.1 install --only-deps /tmp/watchtower-worker-deps-1.0-1.rockspec \
    && rm -f /tmp/watchtower-worker-deps-1.0-1.rockspec

# Bake the app in (prod: no bind mount, unlike dev/docker-compose.yml's
# worker service). Shared Lua modules mirror
# docker/images/prod/server/Dockerfile - see shared/README.md.
COPY worker/lua/ /app
COPY shared/ /shared
# Includes /worker_plugins so the image is self-sufficient for the
# WORKER_CONFIG_FILE `plugins` bind-mount pattern (see
# docker/worker/worker_config.example.lua, docker/worker/crontab.example,
# docker/worker/watchtower-worker.service.example) with no extra -e
# LUA_PATH=... flag required - the directory is a no-op if nothing is
# mounted there.
ENV LUA_PATH="/shared/?.lua;/shared/?/init.lua;/worker_plugins/?.lua;/worker_plugins/?/init.lua;;"

# Dedicated, unprivileged service user.
RUN addgroup -g 1000 -S watchtower \
    && adduser -S -D -H -u 1000 -G watchtower -s /sbin/nologin watchtower \
    && chown -R watchtower:watchtower /app /shared
USER watchtower

WORKDIR /app

ENTRYPOINT ["lua", "/app/main.lua"]
