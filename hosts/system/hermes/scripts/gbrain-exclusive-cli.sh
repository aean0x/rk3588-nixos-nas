#!/usr/bin/env bash
# Pause MCP `gbrain serve` (and its watchdog) so a CLI can open PGLite,
# run the given command as hermes, then resume the watchdog so serve restarts.
#
# Usage (inside hermes-agent container, as root):
#   gbrain-exclusive-cli.sh -- <command> [args...]
#
# Why: mcp_stdio_watchdog immediately restarts `gbrain serve` after a bare
# pkill, so consolidate/embed/dream see "database already open" forever.
set -euo pipefail

if [[ "${1:-}" == "--" ]]; then
  shift
fi
if [[ $# -lt 1 ]]; then
  echo '{"error":"usage","hint":"gbrain-exclusive-cli.sh -- <cmd> [args...]"}' >&2
  exit 2
fi

STOPPED_WATCHDOGS=()
cleanup() {
  local p
  for p in "${STOPPED_WATCHDOGS[@]:-}"; do
    kill -CONT "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

is_watchdog() {
  case "$1" in
    *mcp_stdio_watchdog*) return 0 ;;
    *) return 1 ;;
  esac
}

is_serve() {
  # Only the actual serve process (bun gbrain serve). Never the watchdog
  # whose cmdline *also* contains ".../gbrain serve" as argv.
  case "$1" in
    *mcp_stdio_watchdog*) return 1 ;;
  esac
  case "$1" in
    bun\ *gbrain* | *"/bin/bun "*gbrain*) return 0 ;;
    *) return 1 ;;
  esac
}

# 1) Freeze watchdogs so they cannot respawn serve mid-maintenance.
for proc in /proc/[0-9]*; do
  [[ -r "$proc/cmdline" ]] || continue
  cmd=$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)
  is_watchdog "$cmd" || continue
  pid=${proc#/proc/}
  if kill -STOP "$pid" 2>/dev/null; then
    STOPPED_WATCHDOGS+=("$pid")
  fi
done

# 2) Terminate serve processes (bun gbrain serve).
for proc in /proc/[0-9]*; do
  [[ -r "$proc/cmdline" ]] || continue
  cmd=$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)
  is_serve "$cmd" || continue
  pid=${proc#/proc/}
  kill -TERM "$pid" 2>/dev/null || true
done

# 3) Wait until no serve remains; drop stale PGLite lock dir.
LOCKDIR=/home/hermes/.gbrain/brain.pglite/.gbrain-lock
for _ in $(seq 1 40); do
  serve_alive=0
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    cmd=$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)
    if is_serve "$cmd"; then
      serve_alive=1
      pid=${proc#/proc/}
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  if [[ "$serve_alive" -eq 0 ]]; then
    rm -rf "$LOCKDIR" 2>/dev/null || true
    break
  fi
  sleep 0.25
done

if [[ -e "$LOCKDIR" ]]; then
  # Last resort: force-remove lock when no serve process remains.
  still=0
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    cmd=$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)
    is_serve "$cmd" && still=1
  done
  if [[ "$still" -eq 0 ]]; then
    rm -rf "$LOCKDIR" 2>/dev/null || true
  else
    echo '{"error":"could_not_stop_gbrain_serve","lock":"'"$LOCKDIR"'"}' >&2
    exit 7
  fi
fi

export HOME=/home/hermes
export PATH="/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/usr/bin:/bin${HERMES_NIX_BIN:+:$HERMES_NIX_BIN}"
export HERMES_MEMORY_REGISTRY="${HERMES_MEMORY_REGISTRY:-/data/memory/registry.json}"

# 4) Run the real work as hermes (not root).
_env=(
  HOME=/home/hermes
  PATH="$PATH"
  HERMES_JQ="${HERMES_JQ:-}"
  HERMES_PYTHON3="${HERMES_PYTHON3:-}"
  HERMES_NIX_BIN="${HERMES_NIX_BIN:-}"
  HERMES_MEMORY_REGISTRY="$HERMES_MEMORY_REGISTRY"
  ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY:-}"
  OPENAI_API_KEY="${OPENAI_API_KEY:-}"
  FORCE_GBRAIN_EMBED="${FORCE_GBRAIN_EMBED:-}"
)

if [[ "$(id -u)" -eq 0 ]]; then
  if command -v runuser >/dev/null 2>&1; then
    runuser -u hermes -- env "${_env[@]}" "$@"
  else
    su hermes -s /bin/bash -c 'exec env "$@"' -- "${_env[@]}" "$@"
  fi
else
  env "${_env[@]}" "$@"
fi
# trap resumes watchdogs on EXIT
