# Development

## Run Docker environment

```console
docker compose up -d
```

Go to http://localhost:3000 to access to the UI.

## Non-root service user

All four Docker images (dev/prod `lapis`, dev/prod `worker`) create and run as a
dedicated, unprivileged `watchtower` user (uid/gid `1000`) by default - see
`CLAUDE.md`'s `docker/` layout section.

If you're updating an existing dev checkout that ran these containers as root
before this change, one-time cleanup is needed: nginx's previously-created
`server/logs/`, `server/client_body_temp/`, `server/proxy_temp/`,
`server/fastcgi_temp/`, `server/scgi_temp/`, `server/uwsgi_temp/`, and
`server/nginx.conf.compiled` (all gitignored) are still owned by `root`/`nobody`
from those earlier runs, so the new non-root container can't write into them.
Remove them (likely needs `sudo`, since they're not owned by your host user)
before restarting the stack so nginx recreates them fresh as uid `1000`:

```console
sudo rm -rf server/logs server/client_body_temp server/proxy_temp \
  server/fastcgi_temp server/scgi_temp server/uwsgi_temp \
  server/nginx.conf.compiled
docker compose up -d
```

## Follow logs

```console
docker compose logs -f
```

## Connect to database

```console
docker compose exec db psql -U <database_username> -d <database_name>
```

## Run backend

```console
lapis server development
```

## Run frontend

```console
docker compose exec frontend npm run dev
```

## Build frontend

```
docker compose exec frontend yarn build
```

## Log in / get a token

Every route is authenticated (see `CLAUDE.md`). The dev stack bootstraps an
admin account from `INITIAL_ADMIN_USERNAME`/`INITIAL_ADMIN_PASSWORD` (see
`.env.example`, defaults `admin`/`adminpass`):

```console
curl -s -XPOST localhost:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"adminpass"}'
```

Use the returned `token` as `Authorization: Bearer <token>`, or create an
API key (`POST /api/auth/api_key`, needs `api_key:manage`) and use it as an
`x-api-key` header instead — see `docs/openapi.yaml` for the full route
list and `docs/dev/worker-configuration.md` for how a worker authenticates.

## Run the standalone worker

See `docs/dev/worker-configuration.md` — the `worker` service is idle by
default (no `WORKER_CONFIG_FILE`/`SERVER_API_KEY` configured yet).

Note: `WORKER_CONFIG_FILE`'s `plugins` field defaults to `{}` — this applies
to the embedded worker (`lapis` service) too, so even with `USE_EMBED_WORKER=1`
nothing actually observes until a `WORKER_CONFIG_FILE` exists and its `plugins`
array names `"watchtower_observer_web_scraper.plugin"` (see
`docker/worker/worker_config.example.lua`). Third-party plugin modules go in
`worker_plugins/` (gitignored, bind-mounted into both `lapis` and `worker`)
and are referenced by module path the same way.

## Dev references

lapis: https://leafo.net/lapis/reference.html
tableshape: https://github.com/leafo/tableshape
vite: https://vite.dev/
tailwindcss: https://tailwindcss.com/
pinia: https://pinia.vuejs.org/

# Source to production server

1. Prepare dev files

1.1. Build frontend files and move to the server

```
docker compose exec frontend yarn build
mv public/dist/* server/static
```

2. Stop production env

```
docker compose stop
```

2. Sync files from source to production server

```
export SRC_CODE='<REPLACEME>'
export DESTINATION='USERNAME@host:/path/to/root_path'
rsync -avz --delete --dry-run --exclude 'public/' --exclude 'data/' --exclude .env --exclude 'server/*_temp' --exclude 'server/logs' --exclude 'server/nginx.conf.compiled' --exclude 'docs/' "${SRC_CODE}" "${DESTINATION}"
```

3. Run production env

```
docker compose up -d
```

# Database schema changes

There is no migration system - the whole schema lives in one file,
`config/dataset/init.sql`, applied by Postgres' `docker-entrypoint-initdb.d`
on first boot only. Changing the schema means editing that file and
recreating the volume:

```console
docker compose down -v
docker compose up -d
```

# Issues with xml dependency

Installing xml on alpine:

- https://github.com/lubyk/xml/issues/19#issuecomment-1399366115
