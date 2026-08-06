#!/usr/bin/env bash
# Agent/operator exclusive GBrain CLI guard (does NOT stop hermes-agent).
#
# Refuse if hermes-agent is active or `gbrain serve` is running — those hold
# PGLite. Host maintenance must use hermes-gbrain-exclusive (or the consolidate
# / dream / embed wrappers) which stop the agent first.
#
# Installed at /var/lib/hermes/bin/gbrain-exclusive-cli (bind /data/bin in container).
# Usage: gbrain-exclusive-cli <gbrain-args...>
#   e.g. gbrain-exclusive-cli doctor
#        gbrain-exclusive-cli list -n 5
set -euo pipefail

LOG_TAG="gbrain-exclusive-cli"
HOME_DIR="${HERMES_USER_HOME:-/var/lib/hermes/home}"
# Container path when running inside hermes-agent.
if [[ -d /home/hermes/.gbrain ]] && [[ ! -d "$HOME_DIR/.gbrain" ]]; then
  HOME_DIR=/home/hermes
fi
AGENT_UNIT="${HERMES_AGENT_UNIT:-hermes-agent.service}"

log() {
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",$1}" >&2
}

if [[ $# -eq 0 ]]; then
  log '"error":"usage","hint":"gbrain-exclusive-cli <gbrain args...>  (agent must be stopped)"'
  exit 64
fi

# Refuse if agent or serve holds PGLite.
agent_active=0
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then
    agent_active=1
  fi
fi
# Inside container, systemctl may not see the host unit; also check process list.
serve_alive=0
if pgrep -f 'gbrain serve' >/dev/null 2>&1; then
  serve_alive=1
fi

if [[ "$agent_active" -eq 1 ]] || [[ "$serve_alive" -eq 1 ]]; then
  log "\"error\":\"pglite_busy\",\"hermes_agent_active\":$agent_active,\"gbrain_serve\":$serve_alive,\"hint\":\"stop hermes-agent first, or use host hermes-gbrain-exclusive / hermes-gbrain-consolidate\""
  exit 11
fi

export HOME="$HOME_DIR"
export PATH="${HOME_DIR}/.bun/bin:${HOME_DIR}/.npm-global/bin:/var/lib/hermes/toolbox/bin:/data/toolbox/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

if [[ ! -e /home/hermes ]] && [[ -d "$HOME_DIR" ]]; then
  ln -sfn "$HOME_DIR" /home/hermes 2>/dev/null || true
fi

if ! command -v gbrain >/dev/null 2>&1; then
  log '"error":"gbrain_not_on_path","hint":"bun install -g under hermes HOME"'
  exit 2
fi

# Prefer runuser when root; otherwise run as current user (already hermes).
if [[ "$(id -u)" -eq 0 ]] && id hermes >/dev/null 2>&1; then
  exec runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" \
    ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY:-}" \
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    bash -c 'cd "$HOME" && exec gbrain "$@"' _ "$@"
else
  cd "$HOME_DIR" || cd "$HOME" || true
  exec gbrain "$@"
fi
