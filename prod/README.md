# Init

```console
docker compose up -d
```

Both images run as a dedicated, unprivileged `watchtower` user (uid/gid `1000`) by
default, not root - see `CLAUDE.md`'s `docker/` layout section. Host-side
`worker_plugins/`/`worker_config/` (bind-mounted read-only from this process's
point of view) only need to be readable by that user; Docker's default `root:root`
mode `755` on first auto-create already satisfies that.

# Destroy

```console
docker compose down -v
```
