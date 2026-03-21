# Use the official OpenResty Alpine base image
FROM openresty/openresty:alpine

# Install required packages: build tools, LuaRocks, and Lua development headers
RUN apk add --no-cache build-base luarocks lua5.1-dev openssl-dev && \
  luarocks-5.1 install lapis && luarocks-5.1 install tableshape

ADD entrypoint.sh /

# Set the working directory to /app (where your code resides)
WORKDIR /app

# Expose port 8080 (if needed)
EXPOSE 8080

# Set the command to run your Lapis server in development mode
CMD ["lapis", "server", "development"]
