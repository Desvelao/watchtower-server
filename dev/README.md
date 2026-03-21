# Development

## Run Docker environment

```console
docker compose up -d
```

Go to http://localhost:3000 to access to the UI.

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

## Dev references

lapis: https://leafo.net/lapis/reference.html
tableshape: https://github.com/leafo/tableshape
vite: https://vite.dev/
vuetify:https://vuetifyjs.com
icons: https://pictogrammers.com/library/mdi/

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

# Database migrations

Requirements:

- `luabitop`:

```
luarocks-5.1 install luabitop
```

- migrations.lua

Running a migrations:

```
lapis migrate
```

# Issues with xml dependency

Installing xml on alpine:

- https://github.com/lubyk/xml/issues/19#issuecomment-1399366115
