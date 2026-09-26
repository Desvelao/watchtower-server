# Use the official OpenResty Alpine base image
FROM openresty/openresty:alpine

# Install required packages: build tools, LuaRocks, and Lua development headers
RUN apk add --no-cache build-base luarocks lua5.1-dev openssl-dev git

# Pinned dependency versions - see
# docker/rockspecs/watchtower-server-deps-1.0-1.rockspec for the exact list
# and per-rock rationale.
COPY docker/rockspecs/watchtower-server-deps-1.0-1.rockspec /tmp/watchtower-server-deps-1.0-1.rockspec
RUN luarocks-5.1 install --only-deps /tmp/watchtower-server-deps-1.0-1.rockspec \
    && rm -f /tmp/watchtower-server-deps-1.0-1.rockspec

# Pre-bake observer_configs' scraper rocks (xml, webscraper) at build time,
# mirroring docker/images/dev/worker/Dockerfile and
# docker/images/prod/server/Dockerfile - makes entrypoint.sh's runtime
# re-run of this same setup.sh a no-op (its own luarocks-5.1 show checks
# skip already-installed rocks), so the container doesn't need root/apk
# write access at container start (see the USER switch below).
COPY server/plugins/observer_configs/setup.sh /tmp/scraper-setup/setup.sh
COPY server/plugins/observer_configs/xml.rockspec /tmp/scraper-setup/xml.rockspec
RUN cd /tmp/scraper-setup && sh setup.sh && cd / && rm -rf /tmp/scraper-setup

ADD docker/images/dev/lapis/entrypoint.sh /

# Set the working directory to /app (where your code resides)
WORKDIR /app

# Dedicated, unprivileged service user - the app code is bind-mounted here
# for live editing (see dev/docker-compose.yml), and nginx creates its own
# pid/log/temp paths under this WORKDIR at runtime, so no chown is needed.
RUN addgroup -g 1000 -S watchtower \
    && adduser -S -D -H -u 1000 -G watchtower -s /sbin/nologin watchtower
USER watchtower

# Expose port 8080 (if needed)
EXPOSE 8080

# Set the command to run your Lapis server in development mode
CMD ["lapis", "server", "development"]
