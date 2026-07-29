#!/usr/bin/env bash
# Host-only Hermes → GBrain maintenance.
# Stops hermes-agent so MCP releases PGLite, then runs CLI as hermes, then restarts.
# No docker exec race, no exclusive-cli helper stack.
#
# Scheduled: hermes-gbrain-consolidate.timer (daily + up to 45m random delay).
# Manual: sudo hermes-gbrain-consolidate  (or: systemctl start hermes-gbrain-consolidate.service)
set -euo pipefail

LOG_TAG="hermes-gbrain-consolidate"
STATE="${HERMES_STATE_DIR:-/var/lib/hermes/.hermes}"
MEM_REG="${HERMES_MEMORY_REGISTRY:-/var/lib/hermes/memory/registry.json}"
CANON="${HERMES_MEMORY_CANON:-/var/lib/hermes/memory/AGENTS.md}"
# Container hermes HOME is /home/hermes (bind of this dir). Host passwd home is
# /var/lib/hermes — always force the container-aligned path for gbrain CLI.
HOME_DIR="${HERMES_USER_HOME:-/var/lib/hermes/home}"
export HOME="$HOME_DIR"
export PATH="${HOME_DIR}/.bun/bin:${HOME_DIR}/.npm-global/bin:/var/lib/hermes/toolbox/bin:/run/current-system/sw/bin:/usr/bin:/bin"
export HERMES_MEMORY_REGISTRY="$MEM_REG"

# gbrain config (from container init) stores absolute /home/hermes/... paths.
# Host activation creates /home/hermes → home/; ensure it exists before CLI.
if [[ ! -e /home/hermes ]]; then
  ln -sfn "$HOME_DIR" /home/hermes 2>/dev/null || true
fi

log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",\"msg\":$1}"; }

# runuser as hermes with container-aligned HOME (passwd home is /var/lib/hermes).
gbrain_as_hermes() {
  runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" \
    ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY:-}" \
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    gbrain "$@"
}

started=0
cleanup() {
  if [[ "$started" -eq 1 ]]; then
    systemctl start hermes-agent.service 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ ! -x "$(command -v gbrain 2>/dev/null || true)" ]]; then
  log '"error":"gbrain_not_on_path","hint":"agent should bun install -g github:garrytan/gbrain under hermes HOME"'
  exit 2
fi
if [[ ! -f "$CANON" ]] || [[ ! -f "$STATE/AGENTS.md" ]]; then
  log '"error":"agents_md_missing"'
  exit 3
fi
if ! cmp -s "$CANON" "$STATE/AGENTS.md"; then
  log '"error":"agents_md_drift"'
  exit 4
fi
if [[ ! -d "$HOME_DIR/.gbrain" ]]; then
  log '"error":"gbrain_not_initialized","hint":"run agent bootstrap / gbrain init --pglite under hermes home"'
  exit 5
fi

# Load embedding keys for dream (optional).
if [[ -f "$STATE/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source <(grep -E '^(ZEROENTROPY_API_KEY|OPENAI_API_KEY)=' "$STATE/.env" || true)
  set +a
fi

log '"event":"stopping_hermes_for_pglite"'
systemctl stop hermes-agent.service
started=1
# Wait for lock release
for _ in $(seq 1 60); do
  if [[ ! -e "$HOME_DIR/.gbrain/brain.pglite/.gbrain-lock" ]] \
    && ! pgrep -f 'gbrain serve' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
rm -rf "$HOME_DIR/.gbrain/brain.pglite/.gbrain-lock" 2>/dev/null || true
pkill -f 'gbrain serve' 2>/dev/null || true
sleep 1
chown -R hermes:hermes "$HOME_DIR/.gbrain" "$HOME_DIR/brain" 2>/dev/null || true

# Snapshot MEMORY/USER
UTC=$(date -u +%Y%m%dT%H%M%SZ)
SNAP="$STATE/memories/export/snapshots/$UTC"
mkdir -p "$SNAP" "$STATE/memories/export/inbox" "$STATE/memories/export/inbox/.processed"
for f in MEMORY.md USER.md; do
  if [[ -f "$STATE/memories/$f" ]]; then
    cp -a "$STATE/memories/$f" "$SNAP/$f"
    sha256sum "$SNAP/$f" >"$SNAP/$f.sha256"
  fi
done
chmod -R a-w "$SNAP" 2>/dev/null || true

# Export MEMORY.md into inbox once per snapshot stamp
if [[ -s "$STATE/memories/MEMORY.md" ]]; then
  OUT="$STATE/memories/export/inbox/${UTC}.json"
  if [[ ! -f "$OUT" ]]; then
    BODY=$(python3 -c 'import json,pathlib; print(json.dumps(pathlib.Path("'"$STATE"'/memories/MEMORY.md").read_text()))')
    RID=$(python3 -c 'import uuid; print(uuid.uuid4())')
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    CS=$(sha256sum "$STATE/memories/MEMORY.md" | awk '{print $1}')
    jq -n --arg rid "$RID" --arg now "$NOW" --arg cs "$CS" --argjson body "$BODY" '{
      schema_version: 1,
      record_id: $rid,
      created_at: $now,
      source_agent: "hermes-gateway",
      source_session: "consolidation-export",
      namespace: "default",
      kind: "summary",
      priority: 50,
      confidence: 0.9,
      raw: false,
      body: $body,
      attribution: { hermes_home: "'"$STATE"'", exported_from: "MEMORY.md", checksum_sha256: $cs }
    }' >"$OUT"
  fi
fi

IMPORTED=0
FAILED=0
PENDING=0
PUT_ERR="$STATE/memories/export/last-put.err"
: >"$PUT_ERR"
for j in "$STATE/memories/export/inbox"/*.json; do
  [[ -f "$j" ]] || continue
  PENDING=$((PENDING + 1))
  rid=$(jq -r '.record_id // empty' "$j")
  [[ -n "$rid" ]] || rid=$(basename "$j" .json)
  slug="hermes/inbox/${rid}"
  set +e
  jq -r '.body' "$j" | gbrain_as_hermes put "$slug" >>"$PUT_ERR" 2>&1
  put_ec=$?
  set -e
  if [[ "$put_ec" -eq 0 ]]; then
    IMPORTED=$((IMPORTED + 1))
    mv "$j" "$STATE/memories/export/inbox/.processed/$(basename "$j")"
  else
    FAILED=$((FAILED + 1))
    echo "{\"event\":\"put_failed\",\"file\":\"$(basename "$j")\",\"slug\":\"$slug\",\"exit\":$put_ec}" >>"$PUT_ERR"
  fi
done

DREAM_OK=false
if gbrain_as_hermes dream >>"$PUT_ERR" 2>&1; then
  DREAM_OK=true
fi

SYNC_OK=null
if [[ -d "$HOME_DIR/brain/.git" ]]; then
  if gbrain_as_hermes sync --repo "$HOME_DIR/brain" --no-embed >>"$PUT_ERR" 2>&1; then
    SYNC_OK=true
  else
    SYNC_OK=false
  fi
fi

echo "{\"snapshot\":\"$SNAP\",\"inbox_pending\":$PENDING,\"inbox_imported\":$IMPORTED,\"inbox_failed\":$FAILED,\"dream\":$DREAM_OK,\"brain_sync\":$SYNC_OK}"
log '"status":"complete"'

if [[ "$FAILED" -gt 0 || ( "$PENDING" -gt 0 && "$IMPORTED" -eq 0 ) ]]; then
  log '"error":"put_or_dream_failed","see":"'"$PUT_ERR"'"'
  # Surface gbrain CLI stderr in journal for the operator
  if [[ -s "$PUT_ERR" ]]; then
    echo "--- last-put.err ---" >&2
    cat "$PUT_ERR" >&2 || true
  fi
fi

if [[ "$PENDING" -gt 0 && "$IMPORTED" -eq 0 ]]; then
  exit 8
fi
if [[ "$FAILED" -gt 0 ]]; then
  exit 9
fi
