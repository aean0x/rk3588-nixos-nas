#!/usr/bin/env bash
# Runs inside hermes-agent container (user hermes).
set -euo pipefail

export PATH="/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/usr/bin:/bin${HERMES_NIX_BIN:+:$HERMES_NIX_BIN}"
JQ="${HERMES_JQ:-$(command -v jq 2>/dev/null || true)}"
if [ -z "$JQ" ] || [ ! -x "$JQ" ]; then
  echo '{"error":"jq_missing","hint":"set HERMES_JQ"}' >&2
  exit 2
fi
export HERMES_MEMORY_REGISTRY="${HERMES_MEMORY_REGISTRY:-/data/memory/registry.json}"
MODEL_VERSION="${GBRAIN_EMBED_MODEL_VERSION:-zeroentropy/default}"

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

CANON=/data/memory/AGENTS.md
LIVE=/data/.hermes/AGENTS.md
if [ ! -f "$CANON" ] || [ ! -f "$LIVE" ] || ! cmp -s "$CANON" "$LIVE"; then
  echo '{"error":"agents_md_drift","embed_skipped":true}' >&2
  exit 4
fi

LOCK=/data/.hermes/memories/export/.consolidation.lock
mkdir -p /data/.hermes/memories/export
exec 9>"$LOCK"
if ! flock -n 9; then
  echo '{"skipped":true,"reason":"consolidation_lock_held"}'
  exit 0
fi

STATE=/data/.hermes/memories/export/last-embed-state.json
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DELTA=0
SOURCES='[]'

if [ -s /data/.hermes/memories/MEMORY.md ]; then
  CS=$(sha256sum /data/.hermes/memories/MEMORY.md | awk '{print $1}')
  SOURCES=$(echo "$SOURCES" | $JQ --arg id memory_md --arg cs "$CS" '. + [{source_id:$id,checksum_sha256:$cs}]')
fi
for j in /data/.hermes/memories/export/inbox/.processed/*.json /data/.hermes/memories/export/inbox/*.json; do
  [ -f "$j" ] || continue
  CS=$($JQ -r '.attribution.checksum_sha256 // empty' "$j")
  [ -n "$CS" ] || CS=$(sha256sum "$j" | awk '{print $1}')
  RID=$($JQ -r '.record_id // empty' "$j")
  [ -n "$RID" ] || RID=$(basename "$j" .json)
  SOURCES=$(echo "$SOURCES" | $JQ --arg id "$RID" --arg cs "$CS" '. + [{source_id:$id,checksum_sha256:$cs}]')
done

PREV='{}'
[ -f "$STATE" ] && PREV=$(cat "$STATE")

while read -r row; do
  [ -n "$row" ] || continue
  sid=$(echo "$row" | $JQ -r .source_id)
  cs=$(echo "$row" | $JQ -r .checksum_sha256)
  old=$(echo "$PREV" | $JQ -r --arg sid "$sid" '.sources[]? | select(.source_id==$sid) | .checksum_sha256' | head -1)
  if [ "$old" != "$cs" ]; then
    DELTA=1
    break
  fi
done < <(echo "$SOURCES" | $JQ -c '.[]')

if [ "${FORCE_GBRAIN_EMBED:-}" = 1 ]; then
  DELTA=1
fi

if [ -z "${ZEROENTROPY_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "{\"embed\":\"skip\",\"reason\":\"no_embedding_api_key\",\"delta_detected\":$DELTA}"
  exit 0
fi

if [ "$DELTA" -eq 0 ]; then
  echo "{\"embed\":\"skip\",\"reason\":\"no_checksum_delta\",\"model_version\":\"$MODEL_VERSION\"}"
  exit 0
fi

EMBED_OK=false
if gbrain embed --stale 2>/tmp/gbrain-embed.err; then
  EMBED_OK=true
fi

$JQ -n --arg now "$NOW" --arg mv "$MODEL_VERSION" --argjson sources "$SOURCES" --arg ok "$EMBED_OK" '{
  schema_version: 1,
  embedded_at: $now,
  model_version: $mv,
  embed_ok: ($ok == "true"),
  sources: $sources
}' > "$STATE"

SRC_COUNT=$(echo "$SOURCES" | $JQ 'length')
echo "{\"embed\":$EMBED_OK,\"delta\":true,\"model_version\":\"$MODEL_VERSION\",\"sources\":$SRC_COUNT}"
