#!/usr/bin/env bash
# Runs inside hermes-agent container (user hermes).
set -euo pipefail

export PATH="/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/usr/bin:/bin${HERMES_NIX_BIN:+:$HERMES_NIX_BIN}"
# HERMES_JQ / HERMES_PYTHON set by Nix activation (store paths work: /nix/store is bind-mounted).
JQ="${HERMES_JQ:-$(command -v jq 2>/dev/null || true)}"
PYTHON3="${HERMES_PYTHON3:-$(command -v python3 2>/dev/null || true)}"
if [ -z "$JQ" ] || [ ! -x "$JQ" ]; then
  echo '{"error":"jq_missing","hint":"set HERMES_JQ to pkgs.jq bin path"}' >&2
  exit 2
fi
if [ -z "$PYTHON3" ] || [ ! -x "$PYTHON3" ]; then
  echo '{"error":"python3_missing","hint":"set HERMES_PYTHON3"}' >&2
  exit 2
fi
export HERMES_MEMORY_REGISTRY="${HERMES_MEMORY_REGISTRY:-/data/memory/registry.json}"

load_env_key() {
  local key="$1"
  local line val
  line=""
  grep "^${key}=" /data/.hermes/.env 2>/dev/null | tail -1 > /tmp/hermes-env-line 2>/dev/null || true
  if [ -s /tmp/hermes-env-line ]; then
    line=$(cat /tmp/hermes-env-line)
    val="${line#*=}"
    [ -n "$val" ] && export "${key}=${val}"
  fi
}
if [ -f /data/.hermes/.env ]; then
  load_env_key ZEROENTROPY_API_KEY
  load_env_key OPENAI_API_KEY
fi

REGISTRY="$HERMES_MEMORY_REGISTRY"
if [ ! -f "$REGISTRY" ]; then
  echo "{\"error\":\"registry missing\",\"path\":\"$REGISTRY\"}" >&2
  exit 2
fi

CANON=/data/memory/AGENTS.md
LIVE=/data/.hermes/AGENTS.md
if [ ! -f "$CANON" ]; then
  echo "{\"error\":\"canonical_agents_md_missing\",\"path\":\"$CANON\"}" >&2
  exit 3
fi
if [ ! -f "$LIVE" ]; then
  echo "{\"error\":\"live_agents_md_missing\",\"path\":\"$LIVE\"}" >&2
  exit 3
fi
if ! cmp -s "$CANON" "$LIVE"; then
  echo "{\"error\":\"agents_md_drift\",\"canonical\":\"$CANON\",\"live\":\"$LIVE\"}" >&2
  exit 4
fi

echo "{\"event\":\"startup\",\"registry\":\"$REGISTRY\",\"hermes_memory\":\"$($JQ -r .hermes_memory.builtin_profile.memory_md.container "$REGISTRY")\",\"gbrain_pglite\":\"$($JQ -r .gbrain_memory.pglite_data.container "$REGISTRY")\",\"agents_md_sha256\":\"$(sha256sum "$CANON" | awk '{print $1}')\"}"

LOCK=/data/.hermes/memories/export/.consolidation.lock
mkdir -p /data/.hermes/memories/export/inbox /data/.hermes/memories/export/inbox/.processed /data/.hermes/memories/export/snapshots
exec 9>"$LOCK"
if ! flock -n 9; then
  echo '{"skipped":true,"reason":"consolidation_lock_held"}'
  exit 0
fi

UTC=$(date -u +%Y%m%dT%H%M%SZ)
SNAP=/data/.hermes/memories/export/snapshots/$UTC
mkdir -p "$SNAP"
for f in MEMORY.md USER.md; do
  if [ -f "/data/.hermes/memories/$f" ]; then
    cp -a "/data/.hermes/memories/$f" "$SNAP/$f"
    sha256sum "$SNAP/$f" > "$SNAP/$f.sha256"
  fi
done
chmod -R a-w "$SNAP" 2>/dev/null || true

MANIFEST=/data/.hermes/memories/export/last-manifest.json
$JQ -n --arg utc "$UTC" --arg snap "$SNAP" '{schema_version:1,snapshot_dir:$snap,created_at:$utc,files:([])}' > "$MANIFEST"

# MEMORY.md -> hermes/inbox dump is OPT-IN only (align with outer consolidate).
# Default OFF: exclusive CLI + serve holding PGLite caused corruption.
# Durable notes go via MCP put_page (main sessions / gbrain-memory-flush).
# Enable dump with: GBRAIN_MEMORY_INBOX_DUMP=1
if [ "${GBRAIN_MEMORY_INBOX_DUMP:-0}" = "1" ] && [ -s /data/.hermes/memories/MEMORY.md ]; then
  BODY=$("$PYTHON3" -c 'import json,pathlib; print(json.dumps(pathlib.Path("/data/.hermes/memories/MEMORY.md").read_text()))')
  RID=$("$PYTHON3" -c 'import uuid; print(uuid.uuid4())')
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  CS=$(sha256sum /data/.hermes/memories/MEMORY.md | awk '{print $1}')
  OUT="/data/.hermes/memories/export/inbox/${UTC}.json"
  if [ ! -f "$OUT" ]; then
    $JQ -n --arg rid "$RID" --arg now "$NOW" --arg cs "$CS" --argjson body "$BODY" '{
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
      attribution: { hermes_home: "/data/.hermes", exported_from: "MEMORY.md", checksum_sha256: $cs }
    }' > "$OUT"
  fi
else
  echo "{\"event\":\"memory_inbox_dump_skipped\",\"reason\":\"retired_use_mcp_put_page\"}" >> /data/.hermes/memories/export/last-put.err 2>/dev/null || true
fi

IMPORTED=0
FAILED=0
PENDING=0
PUT_ERR=/data/.hermes/memories/export/last-put.err
: > "$PUT_ERR"
for j in /data/.hermes/memories/export/inbox/*.json; do
  [ -f "$j" ] || continue
  case "$j" in */.processed/*) continue ;; esac
  PENDING=$((PENDING + 1))
  rid=$($JQ -r '.record_id // empty' "$j")
  if [ -z "$rid" ]; then
    rid=$(basename "$j" .json)
  fi
  slug="hermes/inbox/${rid}"
  set +e
  $JQ -r '.body' "$j" | gbrain put "$slug" >>"$PUT_ERR" 2>&1
  put_ec=$?
  set -e
  if [ "$put_ec" -eq 0 ]; then
    IMPORTED=$((IMPORTED + 1))
    mv "$j" "/data/.hermes/memories/export/inbox/.processed/$(basename "$j")"
  else
    FAILED=$((FAILED + 1))
    echo "{\"event\":\"put_failed\",\"file\":\"$(basename "$j")\",\"slug\":\"$slug\",\"exit\":$put_ec}" >>"$PUT_ERR"
  fi
done

DREAM_OK=false
set +e
gbrain dream >>"$PUT_ERR" 2>&1
dream_ec=$?
set -e
if [ "$dream_ec" -eq 0 ]; then
  DREAM_OK=true
fi

# Optional: register ~/brain as a git source if present (idempotent).
SYNC_OK=null
if [ -d /home/hermes/brain/.git ] || [ -d /home/hermes/brain ]; then
  set +e
  gbrain sync --repo /home/hermes/brain --no-embed >>"$PUT_ERR" 2>&1
  sync_ec=$?
  set -e
  if [ "$sync_ec" -eq 0 ]; then
    SYNC_OK=true
  else
    SYNC_OK=false
  fi
fi

echo "{\"snapshot\":\"$SNAP\",\"inbox_pending\":$PENDING,\"inbox_imported\":$IMPORTED,\"inbox_failed\":$FAILED,\"dream\":$DREAM_OK,\"brain_sync\":$SYNC_OK,\"embed\":\"delegated_to_gbrain_embed_timer\"}"

# Non-zero if we had inbox work but imported nothing (PGLite lock / serve race).
if [ "$PENDING" -gt 0 ] && [ "$IMPORTED" -eq 0 ]; then
  echo "{\"error\":\"inbox_import_failed\",\"pending\":$PENDING,\"see\":\"$PUT_ERR\"}" >&2
  exit 8
fi
if [ "$FAILED" -gt 0 ]; then
  echo "{\"error\":\"partial_inbox_import\",\"imported\":$IMPORTED,\"failed\":$FAILED,\"see\":\"$PUT_ERR\"}" >&2
  exit 9
fi
