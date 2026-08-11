#!/usr/bin/env bash
# One-shot: remove Comet + PostgreSQL containers, images, and state after decommission.
# Run on the NAS as root after remote-test removes the module import.
set -euo pipefail

echo "==> stop units if present"
systemctl stop docker-comet.service 2>/dev/null || true
systemctl stop docker-comet-postgres.service 2>/dev/null || true
systemctl disable docker-comet.service 2>/dev/null || true
systemctl disable docker-comet-postgres.service 2>/dev/null || true

echo "==> remove containers"
docker rm -f comet comet-postgres 2>/dev/null || true

echo "==> remove env"
rm -f /run/comet.env

echo "==> remove state dirs"
rm -rf /var/lib/comet /var/lib/comet-postgres

echo "==> drop images (optional)"
docker image rm g0ldyy/comet:latest 2>/dev/null || true
docker image rm postgres:18-alpine 2>/dev/null || true

echo "==> done"
docker ps -a --format '{{.Names}}' | grep -E 'comet|postgres' || echo "(no comet/postgres containers)"
free -h | head -2
