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
# Install Lapis using LuaRocks. lua-resty-jwt's transitive
# resty.openssl.kdf dependency covers server/plugins/security's scrypt
# needs with no extra package; luastash is the embedded worker's pipeline
# runner (only loaded when USE_EMBED_WORKER=1).
RUN apk add --no-cache build-base luarocks lua5.1-dev openssl-dev \
    && luarocks-5.1 install lapis \
    && luarocks-5.1 install tableshape \
    && luarocks-5.1 install lua-resty-jwt \
    && luarocks-5.1 install luastash

# Copy Lapis app
COPY server/ /app
# Shared Lua modules (server + standalone worker) - see shared/README.md
COPY shared/ /shared
ENV LUA_PATH="/shared/?.lua;/shared/?/init.lua;;"

WORKDIR /app

# Remove current files on static directory
RUN rm -rf ./static/* && \
   mkdir -p logs
# Copy frontend build output into Lapis static directory
COPY --from=frontend-builder /frontend/dist ./static

# Run the setup of the plugins
RUN find $(pwd)/plugins -type f -name "setup.sh" -exec sh -c 'cd "$(dirname "$1")" && sh "$1"' _ {} \;

# Expose port 8080 (if needed)
EXPOSE 8080

# Set the command to run your Lapis server in development mode
CMD ["lapis", "server", "production"]
