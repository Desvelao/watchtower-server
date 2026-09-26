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
