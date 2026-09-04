# Placeholder for the standalone scrape worker image (Phase 5 of the
# platform port). Not yet functional - just enough to let `docker compose
# up` build the `worker` service (which sits idle via `tail -f /dev/null`
# in dev, see dev/docker-compose.yml) before the real worker code exists.
FROM alpine:3.20
CMD ["tail", "-f", "/dev/null"]
