#!/usr/bin/env bash
# Shared exclusive PGLite runner for host GBrain maintenance.
#
# PGLite is single-writer. MCP `gbrain serve` (via hermes-agent) and host CLI
# must never open brain.pglite at the same time. This wrapper is the one code
# path for consolidate / dream / embed (and any other exclusive host job):
#
#   1. flock /run/hermes-gbrain-exclusive.lock
#   2. stop hermes-agent (releases MCP serve)
#   3. wait until no `gbrain serve` and no brain.pglite/.gbrain-lock
#   4. clear stale .gbrain-lock only after stop is clean
#   5. run payload (default: as hermes with HOME/cwd under hermes home)
#   6. trap EXIT → always restart hermes-agent
#
# Usage:
#   hermes-gbrain-exclusive -- <cmd> [args...]          # as hermes
#   hermes-gbrain-exclusive --as-root -- <cmd> [args...]  # as root (host oneshots)
#
# Structured JSON logs on stdout (component=hermes-gbrain-exclusive).
# Never auto-reinits PGLite — prevention only; recovery is operator/docs.
set -euo pipefail

LOG_TAG="hermes-gbrain-exclusive"
LOCK_FILE="${HERMES_GBRAIN_EXCLUSIVE_LOCK:-/run/hermes-gbrain-exclusive.lock}"
HOME_DIR="${HERMES_USER_HOME:-/var/lib/hermes/home}"
PGLITE_LOCK="${HOME_DIR}/.gbrain/brain.pglite/.gbrain-lock"
WAIT_SECS="${HERMES_GBRAIN_EXCLUSIVE_WAIT:-90}"
LOCK_WAIT_SECS="${HERMES_GBRAIN_EXCLUSIVE_FLOCK_WAIT:-600}"
AGENT_UNIT="${HERMES_AGENT_UNIT:-hermes-agent.service}"

export PATH="${HOME_DIR}/.bun/bin:${HOME_DIR}/.npm-global/bin:/var/lib/hermes/toolbox/bin:/run/current-system/sw/bin:/usr/bin:/bin${PATH:+:$PATH}"

log() {
  # $1 = bare JSON object fields (no outer braces), e.g. "event":"x","foo":1
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",$1}"
}

AS_ROOT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --as-root)
      AS_ROOT=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      log "\"error\":\"unknown_flag\",\"flag\":\"$1\""
      exit 64
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  log '"error":"usage","hint":"hermes-gbrain-exclusive [--as-root] -- <command> [args...]"'
  exit 64
fi

# Container-facing absolute paths in gbrain config need /home/hermes on host.
if [[ ! -e /home/hermes ]]; then
  ln -sfn "$HOME_DIR" /home/hermes 2>/dev/null || true
fi

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -w "$LOCK_WAIT_SECS" 9; then
  log "\"error\":\"exclusive_lock_timeout\",\"lock\":\"$LOCK_FILE\",\"wait_secs\":$LOCK_WAIT_SECS"
  exit 1
fi
log "\"event\":\"exclusive_lock_acquired\",\"lock\":\"$LOCK_FILE\""

agent_was_active=0
if systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then
  agent_was_active=1
fi

stopped=0
cleanup() {
  local ec=$?
  # Always restart if we stopped the unit (or it was active when we began).
  if [[ "$stopped" -eq 1 ]] || [[ "$agent_was_active" -eq 1 ]]; then
    log '"event":"restarting_hermes_agent"'
    systemctl start "$AGENT_UNIT" 2>/dev/null || true
  fi
  log "\"event\":\"exclusive_exit\",\"exit\":$ec"
  # Do not re-exit: let the original status propagate when called via trap on EXIT
  # after an intentional exit. trap EXIT runs after exit; we must preserve $ec.
  exit "$ec"
}
trap cleanup EXIT

log "\"event\":\"stopping_hermes_for_pglite\",\"unit\":\"$AGENT_UNIT\""
systemctl stop "$AGENT_UNIT" 2>/dev/null || true
stopped=1

# Wait until serve is gone and lock file is absent (or becomes stale after stop).
wait_ticks=0
max_ticks=$((WAIT_SECS * 2))
for ((i = 1; i <= max_ticks; i++)); do
  serve_alive=0
  lock_present=0
  if pgrep -f 'gbrain serve' >/dev/null 2>&1; then
    serve_alive=1
  fi
  if [[ -e "$PGLITE_LOCK" ]]; then
    lock_present=1
  fi
  if [[ "$serve_alive" -eq 0 && "$lock_present" -eq 0 ]]; then
    wait_ticks=$i
    break
  fi
  sleep 0.5
  wait_ticks=$i
done

if pgrep -f 'gbrain serve' >/dev/null 2>&1; then
  log '"event":"serve_still_alive_after_stop","action":"pkill"'
  pkill -f 'gbrain serve' 2>/dev/null || true
  sleep 2
fi

if pgrep -f 'gbrain serve' >/dev/null 2>&1; then
  log '"error":"serve_still_alive","hint":"refusing to open PGLite while gbrain serve holds it; check mcp_stdio_watchdog / docker"'
  exit 10
fi

# Clear stale lock only after stop is clean (no live serve).
if [[ -e "$PGLITE_LOCK" ]]; then
  log "\"event\":\"clearing_stale_gbrain_lock\",\"path\":\"$PGLITE_LOCK\""
  rm -rf "$PGLITE_LOCK" 2>/dev/null || true
fi

log "\"event\":\"pglite_exclusive_ready\",\"wait_ticks\":$wait_ticks,\"as_root\":$AS_ROOT"

payload_ec=0
set +e
if [[ "$AS_ROOT" -eq 1 ]]; then
  # Host oneshots (consolidate) that need root for snapshots/chown, then runuser for gbrain.
  "$@"
  payload_ec=$?
else
  # Default: run as hermes with container-aligned HOME and cwd under HOME
  # (bun inherits invoker cwd; wrong cwd → false EACCES on git spawn).
  runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" \
    ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY:-}" \
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    bash -c 'cd "$HOME" && exec "$@"' _ "$@"
  payload_ec=$?
fi
set -e

# Surface WASM / multi-instance class without auto-reinit.
if [[ "$payload_ec" -ne 0 ]]; then
  log "\"event\":\"payload_failed\",\"exit\":$payload_ec,\"hint\":\"if WASM Aborted or module already instantiated: stop concurrent CLI, exclusive gbrain doctor, backup brain.pglite, reinit-pglite only if doctor confirms damage — never auto-reinit\""
fi

exit "$payload_ec"
