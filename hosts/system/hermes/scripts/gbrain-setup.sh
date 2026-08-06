#!/usr/bin/env bash
# Rocknas GBrain post-install setup (operator / ./deploy).
#
# Run on the device as root (or via: scp + sudo bash). Idempotent.
# Declarative pieces (systemd gbrain-mcp-http, MCP url, plugins) come from Nix;
# this script covers everything that is still one-shot / Hermes-home state.
#
# Catalogue (fresh machine after remote-switch):
#   1. bun + gbrain CLI (bun global under hermes HOME)
#   2. gbrain init --pglite (if no PGLite dir)
#   3. ~/brain git tree + config (search.mode, sources path)
#   4. HTTP sole-owner unit up (gbrain-mcp-http)
#   5. Bearer token for Hermes MCP clients (auth create → token file + .env)
#   6. Wire config.yaml headers (url + Authorization)
#   7. Import ~/brain markdown if present (serve stopped)
#   8. Embed --stale with ZEROENTROPY (serve stopped)
#   9. Start HTTP serve + restart hermes-agent (+ webui if enabled)
#  10. Smoke: health, hermes mcp test / list
#
# NEVER: gbrain autopilot --install alongside serve (second PGLite writer)
# NEVER: exclusive consolidate/dream host timers
# NEVER: per-agent stdio gbrain serve as primary MCP
#
set -euo pipefail

HERMES_HOME_DIR="${HERMES_HOME_DIR:-/var/lib/hermes/home}"
HERMES_STATE="${HERMES_STATE:-/var/lib/hermes/.hermes}"
GBRAIN_HOME="${HERMES_HOME_DIR}/.gbrain"
BRAIN_REPO="${HERMES_HOME_DIR}/brain"
TOKEN_FILE="${GBRAIN_HOME}/hermes-mcp.token"
HERMES_ENV_FILE="${HERMES_STATE}/.env"
HERMES_CFG="${HERMES_STATE}/config.yaml"
BUN_BIN="${HERMES_HOME_DIR}/.bun/bin"
GBRAIN_BIN="${BUN_BIN}/gbrain"
MCP_URL="${GBRAIN_MCP_URL:-http://127.0.0.1:3131/mcp}"
SEARCH_MODE="${GBRAIN_SEARCH_MODE:-balanced}"
TOKEN_NAME="${GBRAIN_TOKEN_NAME:-hermes-agents}"

log() { echo "[gbrain-setup] $*"; }
warn() { echo "[gbrain-setup] WARN: $*" >&2; }
die() { echo "[gbrain-setup] FAIL: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"

as_hermes() {
  # shellcheck disable=SC2086
  sudo -u hermes env HOME="${HERMES_HOME_DIR}" \
    PATH="${BUN_BIN}:/run/current-system/sw/bin:/usr/bin:/bin" \
    ${ZEROENTROPY_API_KEY:+ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY}"} \
    "$@"
}

load_ze() {
  if [[ -f /run/hermes.env ]]; then
    # shellcheck disable=SC1091
    set -a
    # shellcheck source=/dev/null
    . /run/hermes.env
    set +a
  fi
  if [[ -z "${ZEROENTROPY_API_KEY:-}" ]]; then
    warn "ZEROENTROPY_API_KEY not in /run/hermes.env — keyword search works; embed may no-op"
  else
    log "ZEROENTROPY_API_KEY present (len=${#ZEROENTROPY_API_KEY})"
  fi
}

stop_brain_consumers() {
  log "stopping hermes-webui, hermes-agent, gbrain-mcp-http"
  systemctl stop hermes-webui 2>/dev/null || true
  systemctl stop hermes-agent 2>/dev/null || true
  systemctl stop gbrain-mcp-http 2>/dev/null || true
  sleep 1
  pkill -9 -f '[g]brain' 2>/dev/null || true
  sleep 1
  pgrep -a gbrain >/dev/null 2>&1 && warn "gbrain still running" || log "no gbrain processes"
}

ensure_dirs() {
  install -d -m 0755 -o hermes -g hermes "${HERMES_HOME_DIR}"
  install -d -m 0755 -o hermes -g hermes "${GBRAIN_HOME}"
  install -d -m 0755 -o hermes -g hermes "${GBRAIN_HOME}/audit"
  install -d -m 0755 -o hermes -g hermes "${BRAIN_REPO}"
  install -d -m 0755 -o hermes -g hermes "${HERMES_STATE}"
  if [[ ! -e /home/hermes ]]; then
    ln -sfn "${HERMES_HOME_DIR}" /home/hermes
  fi
}

ensure_bun_gbrain() {
  if [[ ! -x "${GBRAIN_BIN}" ]]; then
    log "installing bun + gbrain CLI for hermes"
    if [[ ! -x "${BUN_BIN}/bun" ]]; then
      as_hermes bash -c 'curl -fsSL https://bun.sh/install | bash'
    fi
    as_hermes bash -c 'export PATH="$HOME/.bun/bin:$PATH"; bun install -g github:garrytan/gbrain'
  fi
  [[ -x "${GBRAIN_BIN}" ]] || die "gbrain binary missing at ${GBRAIN_BIN}"
  log "gbrain: $(as_hermes "${GBRAIN_BIN}" --version 2>/dev/null | head -1 || echo ok)"
}

ensure_init() {
  if [[ ! -d "${GBRAIN_HOME}/brain.pglite" ]]; then
    log "gbrain init --pglite"
    as_hermes "${GBRAIN_BIN}" init --pglite || as_hermes "${GBRAIN_BIN}" init
  else
    log "PGLite dir exists — skip init"
  fi
  if [[ ! -d "${BRAIN_REPO}/.git" ]]; then
    as_hermes git -C "${BRAIN_REPO}" init
    log "git init ${BRAIN_REPO}"
  fi
  as_hermes "${GBRAIN_BIN}" config set search.mode "${SEARCH_MODE}" 2>/dev/null || true
  # Pin markdown source path (PGLite sources table may need this later)
  as_hermes "${GBRAIN_BIN}" config set brain_repo "${BRAIN_REPO}" 2>/dev/null || true
  as_hermes "${GBRAIN_BIN}" config set repo "${BRAIN_REPO}" 2>/dev/null || true
}

mint_token() {
  if [[ -s "${TOKEN_FILE}" ]]; then
    log "token file exists ${TOKEN_FILE} — skip mint"
    return 0
  fi
  log "minting HTTP MCP token (${TOKEN_NAME})"
  # auth create needs a live HTTP serve on many builds — brief start
  systemctl start gbrain-mcp-http 2>/dev/null || true
  sleep 2
  # Some builds want serve up; others work offline. Capture token only.
  out=$(as_hermes "${GBRAIN_BIN}" auth create "${TOKEN_NAME}" 2>&1 || true)
  echo "${out}" | tail -20
  # Prefer explicit token line / last non-empty token-like string
  tok=$(echo "${out}" | grep -Eo 'gb_[A-Za-z0-9_-]+|Bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*' | tail -1 | sed 's/^Bearer[[:space:]]*//')
  if [[ -z "${tok}" ]]; then
    # Second try: auth create --json if available
    out=$(as_hermes "${GBRAIN_BIN}" auth create "${TOKEN_NAME}" --json 2>&1 || true)
    tok=$(echo "${out}" | grep -Eo '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  fi
  if [[ -z "${tok}" ]]; then
    warn "could not parse token from auth create — mint manually:"
    warn "  sudo systemctl start gbrain-mcp-http"
    warn "  sudo -u hermes env HOME=${HERMES_HOME_DIR} PATH=${BUN_BIN}:\$PATH gbrain auth create ${TOKEN_NAME}"
    warn "  save token to ${TOKEN_FILE} (mode 600) and GBRAIN_REMOTE_TOKEN in ${HERMES_ENV_FILE}"
    return 1
  fi
  umask 077
  printf '%s\n' "${tok}" >"${TOKEN_FILE}"
  chown hermes:hermes "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
  log "wrote ${TOKEN_FILE}"
  # Hermes .env for any client that reads GBRAIN_REMOTE_TOKEN
  touch "${HERMES_ENV_FILE}"
  chown hermes:hermes "${HERMES_ENV_FILE}"
  chmod 600 "${HERMES_ENV_FILE}"
  if grep -q '^GBRAIN_REMOTE_TOKEN=' "${HERMES_ENV_FILE}" 2>/dev/null; then
    sed -i "s|^GBRAIN_REMOTE_TOKEN=.*|GBRAIN_REMOTE_TOKEN=${tok}|" "${HERMES_ENV_FILE}"
  else
    printf '\nGBRAIN_REMOTE_TOKEN=%s\n' "${tok}" >>"${HERMES_ENV_FILE}"
  fi
  chown hermes:hermes "${HERMES_ENV_FILE}"
  log "updated GBRAIN_REMOTE_TOKEN in ${HERMES_ENV_FILE}"
}

wire_hermes_mcp_config() {
  [[ -f "${HERMES_CFG}" ]] || {
    warn "no ${HERMES_CFG} yet — start hermes once, re-run setup"
    return 0
  }
  local token=""
  if [[ -s "${TOKEN_FILE}" ]]; then
    token=$(tr -d '\r\n' <"${TOKEN_FILE}")
  fi
  python3 - "${HERMES_CFG}" "${MCP_URL}" "${token}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit(0)
path, url, token = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
data = yaml.safe_load(path.read_text()) or {}
mcp = data.setdefault("mcp_servers", {})
desired = {
    "url": url,
    "connect_timeout": 120,
    "timeout": 120,
    "enabled": True,
}
if token:
    desired["headers"] = {"Authorization": f"Bearer {token}"}
elif isinstance((mcp.get("gbrain") or {}).get("headers"), dict):
    desired["headers"] = mcp["gbrain"]["headers"]
if mcp.get("gbrain") != desired:
    mcp["gbrain"] = desired
    path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
    print("config.yaml gbrain MCP updated (HTTP + bearer)")
else:
    print("config.yaml gbrain MCP already correct")
PY
  chown hermes:hermes "${HERMES_CFG}"
}

import_and_embed() {
  stop_brain_consumers
  local n
  n=$(find "${BRAIN_REPO}" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${n}" -gt 0 ]]; then
    log "import ${n} markdown files from ${BRAIN_REPO}"
    as_hermes "${GBRAIN_BIN}" import "${BRAIN_REPO}" --no-embed || warn "import had errors"
  else
    log "no markdown under ${BRAIN_REPO} — skip import"
  fi
  if [[ -n "${ZEROENTROPY_API_KEY:-}" ]]; then
    log "gbrain embed --stale"
    as_hermes "${GBRAIN_BIN}" embed --stale || warn "embed had errors"
  else
    warn "skip embed (no ZEROENTROPY_API_KEY)"
  fi
}

start_stack() {
  log "starting gbrain-mcp-http (sole PGLite owner)"
  systemctl reset-failed gbrain-mcp-http 2>/dev/null || true
  systemctl start gbrain-mcp-http
  sleep 3
  systemctl is-active --quiet gbrain-mcp-http || die "gbrain-mcp-http failed — journalctl -u gbrain-mcp-http"
  if ss -ltn 2>/dev/null | grep -q ':3131'; then
    log "listening on 127.0.0.1:3131"
  else
    warn "nothing on :3131 yet"
  fi
  curl -sS -m 3 http://127.0.0.1:3131/health && echo || warn "health check failed"
  log "starting hermes-agent"
  systemctl start hermes-agent
  systemctl start hermes-webui 2>/dev/null || true
  sleep 2
  systemctl is-active hermes-agent && log "hermes-agent active"
}

smoke() {
  log "smoke"
  systemctl is-active gbrain-mcp-http hermes-agent || true
  if command -v hermes >/dev/null 2>&1 || [[ -x /run/current-system/sw/bin/hermes ]]; then
    sudo -u hermes env HOME="${HERMES_HOME_DIR}" HERMES_HOME="${HERMES_STATE}" \
      PATH="/var/lib/hermes/bin:/run/current-system/sw/bin:${BUN_BIN}" \
      hermes mcp test gbrain 2>&1 | tail -20 || warn "hermes mcp test failed (session/auth?)"
  fi
  log "done — stock gbrain + HTTP sole-owner + two plugins (retrieval-reflex, memory-flush)"
  log "do NOT install gbrain autopilot daemon on this host"
}

main() {
  load_ze
  ensure_dirs
  ensure_bun_gbrain
  stop_brain_consumers
  ensure_init
  # Token mint may need HTTP serve briefly
  systemctl start gbrain-mcp-http 2>/dev/null || true
  sleep 2
  mint_token || true
  wire_hermes_mcp_config
  import_and_embed
  start_stack
  # Re-wire after start in case setup rewrote config
  wire_hermes_mcp_config
  systemctl restart hermes-agent 2>/dev/null || true
  systemctl restart hermes-webui 2>/dev/null || true
  smoke
}

main "$@"
