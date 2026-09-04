# Use the official OpenResty Alpine base image
FROM openresty/openresty:alpine

# Install required packages: build tools, LuaRocks, and Lua development headers
# lua-resty-jwt pulls in resty.openssl.kdf as a transitive dependency,
# which server/plugins/security/services/password_hash.lua needs for
# scrypt - no separate package required for that.
# luastash is the embedded worker's pipeline runner (see
# shared/worker_pipeline.lua, only loaded when USE_EMBED_WORKER=1) - a
# plain Lua library, not a resty.* module, so it installs the same way on
# both this image and the standalone worker's plain-Lua one.
RUN apk add --no-cache build-base luarocks lua5.1-dev openssl-dev && \
  luarocks-5.1 install lapis && luarocks-5.1 install tableshape && \
  luarocks-5.1 install lua-resty-jwt && \
  luarocks-5.1 install luastash

ADD entrypoint.sh /

# Set the working directory to /app (where your code resides)
WORKDIR /app

# Expose port 8080 (if needed)
EXPOSE 8080

# Set the command to run your Lapis server in development mode
CMD ["lapis", "server", "development"]
