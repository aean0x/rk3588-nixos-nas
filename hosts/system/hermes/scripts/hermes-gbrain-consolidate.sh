#!/usr/bin/env bash
# Idempotent Hermes → G-Brain consolidation (host wrapper → container inner script).
set -euo pipefail

LOG_TAG="hermes-gbrain-consolidate"
CONTAINER="${HERMES_CONTAINER:-hermes-agent}"
INNER="${HERMES_GBRAIN_CONSOLIDATE_INNER:-/data/bin/hermes-gbrain-consolidate-inner}"

log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",\"msg\":$1}"; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  log '"error":"container not found"'
  exit 1
fi
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  log '"error":"container not running"'
  exit 1
fi

docker exec "$CONTAINER" pkill -f 'gbrain serve' 2>/dev/null || true
sleep 2
docker exec "$CONTAINER" chown -R hermes:hermes /home/hermes/.gbrain /home/hermes/brain 2>/dev/null || true

docker exec -u hermes "$CONTAINER" /usr/bin/bash "$INNER"
log '"status":"complete"'
