# --- Stage 1: Build frontend assets ---
FROM node:18-alpine AS frontend-builder

WORKDIR /frontend
COPY public/package.json public/yarn.lock ./

COPY public/ .
RUN yarn && yarn build

# --- Stage 2: Build OpenResty + Lapis ---
FROM openresty/openresty:alpine

# Install required packages: build tools, LuaRocks, and Lua development headers
# Install Lapis using LuaRocks
RUN apk add --no-cache build-base luarocks lua5.1-dev openssl-dev \
    && luarocks-5.1 install lapis \
    && luarocks-5.1 install tableshape

# Copy Lapis app
COPY server/ /app

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
