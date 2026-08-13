#!/usr/bin/env bash
# Selective Hermes reset on hermes-01: keep gbrain (~/brain, ~/.bun), declarative
# config/.env; wipe workspace, sessions, runtime DBs/logs, browser-harness, and
# non-gbrain identity/memory docs. Run on device as root (via sudo).
set -euo pipefail

HERMES_STATE=/var/lib/hermes
HERMES_HOME="${HERMES_STATE}/.hermes"
CONTAINER_HOME="${HERMES_STATE}/home"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

echo "=== Stopping Hermes gateway + WebUI ==="
systemctl stop hermes-webui.service 2>/dev/null || true
systemctl stop hermes-agent.service

echo "=== Preserving gbrain: ${CONTAINER_HOME}/brain, ${CONTAINER_HOME}/.bun ==="

echo "=== Removing non-gbrain home artifacts ==="
rm -rf "${CONTAINER_HOME}/browser-harness"

echo "=== Wiping workspace ==="
find "${HERMES_STATE}/workspace" -mindepth 1 -delete 2>/dev/null || true
install -d -m 2770 -o hermes -g hermes "${HERMES_STATE}/workspace"

echo "=== Clearing ephemeral Hermes runtime state ==="
for path in \
  "${HERMES_HOME}/sessions" \
  "${HERMES_HOME}/cache" \
  "${HERMES_HOME}/images" \
  "${HERMES_HOME}/sandboxes" \
  "${HERMES_HOME}/cron/output" \
  "${HERMES_HOME}/logs" \
  "${HERMES_HOME}/plugins" \
  ; do
  rm -rf "$path"
done
install -d -m 0750 -o hermes -g hermes "${HERMES_HOME}/logs"
install -d -m 2770 -o hermes -g hermes "${HERMES_HOME}/plugins"
install -d -m 0750 -o hermes -g hermes "${HERMES_HOME}/sessions"
install -d -m 0750 -o hermes -g hermes "${HERMES_HOME}/cron/output"

rm -f \
  "${HERMES_HOME}/state.db" "${HERMES_HOME}/state.db-shm" "${HERMES_HOME}/state.db-wal" \
  "${HERMES_HOME}/response_store.db" "${HERMES_HOME}/response_store.db-shm" "${HERMES_HOME}/response_store.db-wal" \
  "${HERMES_HOME}/kanban.db" "${HERMES_HOME}/kanban.db.init.lock" \
  "${HERMES_HOME}/gateway_state.json" \
  "${HERMES_HOME}/.hermes_history" \
  "${HERMES_HOME}/models_dev_cache.json" \
  "${HERMES_HOME}/processes.json" \
  "${HERMES_HOME}/channel_directory.json" \
  "${HERMES_HOME}/.skills_prompt_snapshot.json" \
  "${HERMES_HOME}/memories/MEMORY.md.lock"

if [ -f "${HERMES_HOME}/.env" ]; then
  sed -i '/^MESSAGING_CWD=/d;/^TERMINAL_CWD=/d' "${HERMES_HOME}/.env"
  chown hermes:hermes "${HERMES_HOME}/.env"
  chmod 640 "${HERMES_HOME}/.env"
fi

echo "=== Reset identity stubs (SOUL / USER) if seed files provided ==="
if [ -n "${SOUL_SEED:-}" ] && [ -f "$SOUL_SEED" ]; then
  install -m 0640 -o hermes -g hermes "$SOUL_SEED" "${HERMES_HOME}/SOUL.md"
fi
if [ -n "${USER_SEED:-}" ] && [ -f "$USER_SEED" ]; then
  install -m 0640 -o hermes -g hermes "$USER_SEED" "${HERMES_HOME}/memories/USER.md"
fi

echo "=== Memory manifest AGENTS.md (optional seed paths) ==="
MANIFEST="${AGENTS_MANIFEST:-${AGENTS_GBRAIN:-}}"
if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
  install -m 0640 -o hermes -g hermes "$MANIFEST" "${HERMES_HOME}/AGENTS.md"
fi
if [ -n "${MEMORY_GBRAIN:-}" ] && [ -f "$MEMORY_GBRAIN" ]; then
  install -m 0640 -o hermes -g hermes "$MEMORY_GBRAIN" "${HERMES_HOME}/memories/MEMORY.md"
fi

echo "=== Starting Hermes gateway + WebUI ==="
systemctl start hermes-agent.service
systemctl start hermes-webui.service 2>/dev/null || true

echo "=== Clean complete ==="
