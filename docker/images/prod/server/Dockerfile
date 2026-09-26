# --- Stage 1: Build frontend assets ---
# Node 22, not 18: Tailwind 4's @tailwindcss/oxide needs Node >= 20, and
# vitest 4's own toolchain (nopt, transitively) needs >= 22.
FROM node:22-alpine AS frontend-builder

WORKDIR /frontend
COPY public/package.json public/yarn.lock ./

COPY public/ .
RUN yarn && yarn build

# --- Stage 2: Build OpenResty + Lapis ---
FROM openresty/openresty:alpine

# Install required packages: build tools, LuaRocks, and Lua development headers
RUN apk add --no-cache build-base luarocks lua5.1-dev openssl-dev git

# Pinned dependency versions - see
# docker/rockspecs/watchtower-server-deps-1.0-1.rockspec for the exact list
# and per-rock rationale.
COPY docker/rockspecs/watchtower-server-deps-1.0-1.rockspec /tmp/watchtower-server-deps-1.0-1.rockspec
RUN luarocks-5.1 install --only-deps /tmp/watchtower-server-deps-1.0-1.rockspec \
    && rm -f /tmp/watchtower-server-deps-1.0-1.rockspec

# Copy Lapis app
COPY server/ /app
# Shared Lua modules (server + standalone worker) - see shared/README.md
COPY shared/ /shared
# Includes /worker_plugins so the image is self-sufficient for the
# WORKER_CONFIG_FILE `plugins` bind-mount pattern (see
# docker/worker/worker_config.example.lua) under any orchestrator, not just
# this repo's own prod/docker-compose.yml - the directory is a no-op if
# nothing is mounted there.
ENV LUA_PATH="/shared/?.lua;/shared/?/init.lua;/worker_plugins/?.lua;/worker_plugins/?/init.lua;;"

WORKDIR /app

# Remove current files on static directory
RUN rm -rf ./static/* && \
   mkdir -p logs
# Copy frontend build output into Lapis static directory
COPY --from=frontend-builder /frontend/dist ./static

# Run the setup of the plugins
RUN find $(pwd)/plugins -type f -name "setup.sh" -exec sh -c 'cd "$(dirname "$1")" && sh "$1"' _ {} \;

# Dedicated, unprivileged service user - owns everything the running
# server writes at runtime (nginx's pid/log files and temp dirs, Lapis's
# compiled nginx.conf, all created under WORKDIR /app).
RUN addgroup -g 1000 -S watchtower \
    && adduser -S -D -H -u 1000 -G watchtower -s /sbin/nologin watchtower \
    && chown -R watchtower:watchtower /app /shared
USER watchtower

# Expose port 8080 (if needed)
EXPOSE 8080

# Set the command to run your Lapis server in development mode
CMD ["lapis", "server", "production"]
