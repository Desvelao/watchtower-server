# Description

Decoupled architecture to manage the monitoring of items, allowing to define the items to monitor, notification channels and alerts exposed through an API, so other services can consume and use this definitions to monitor the data, and notify the alerts.

# Architecture

## Server

Provide an API to interact with the database to manage the items to monitor, notification channels and alerts and serve the frontend.

Additionally it allows to store records of historical monitoring if configured.

Technologies:

- Openresty
- Lua
- PostgresSQL
- Vue
- Vuetify

# Deploy

```
cd prod
docker compose up -d
```

# Objectives

Learn about:

- Openresty
- Lapis
- PostgresSQL
- Scraping data
- Vue
- Vuetify: https://vuetifyjs.com/en/components

Enhance:

- Lua
