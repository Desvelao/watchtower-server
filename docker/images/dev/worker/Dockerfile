# Standalone observe worker: Lua 5.1 + LuaRocks built from source on
# Alpine (no OpenResty needed - this is a plain Lua process, not an nginx
# worker).
# Build context is the repo root (see dev/docker-compose.yml) so this can
# reuse the observer_configs plugin's xml-dependency fix (see
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

# Dedicated, unprivileged service user - /app is bind-mounted for live
# editing (see dev/docker-compose.yml), read-only from this process's own
# point of view, so no chown is needed.
RUN addgroup -g 1000 -S watchtower \
    && adduser -S -D -H -u 1000 -G watchtower -s /sbin/nologin watchtower
USER watchtower

WORKDIR /app

ENTRYPOINT ["lua", "/app/main.lua"]
