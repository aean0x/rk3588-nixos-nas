#!/usr/bin/env bash
# Host-only GBrain maintenance (exclusive CLI via hermes-gbrain-exclusive).
#
# Stops hermes-agent so MCP releases PGLite, then runs CLI as hermes, then restarts.
# Exclusive acquire/stop/wait/restart lives in hermes-gbrain-exclusive (one code path).
#
# Scope (after 2026-07-31):
#   - Snapshot MEMORY/USER for audit
#   - Optional emergency MEMORY inbox dump only if GBRAIN_MEMORY_INBOX_DUMP=1
#   - Import ~/brain markdown via put
#   - dream
# Day-to-day durable facts: MCP put_page while gateway is up (not this script).
#
# Scheduled: hermes-gbrain-consolidate.timer (daily + random delay).
# Manual: sudo hermes-gbrain-consolidate
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

log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",$1}"; }

# Re-exec under exclusive runner (flock + stop agent + wait + restart on EXIT).
# HERMES_GBRAIN_EXCLUSIVE=1 is set by the runner / second stage.
if [[ "${HERMES_GBRAIN_EXCLUSIVE:-}" != 1 ]]; then
  EXCL="${HERMES_GBRAIN_EXCLUSIVE_BIN:-hermes-gbrain-exclusive}"
  if ! command -v "$EXCL" >/dev/null 2>&1; then
    log "\"error\":\"exclusive_runner_missing\",\"hint\":\"deploy hermes-gbrain-exclusive\""
    exit 2
  fi
  log '"event":"delegating_to_exclusive_runner"'
  exec "$EXCL" --as-root -- env HERMES_GBRAIN_EXCLUSIVE=1 "$0" "$@"
fi

# Container-facing brain checkout (git + markdown). Prefer this path so gbrain
# resolves the same absolute paths as MCP (config uses /home/hermes/...).
BRAIN_DIR="${HERMES_BRAIN_DIR:-/home/hermes/brain}"

# runuser as hermes with container-aligned HOME (passwd home is /var/lib/hermes).
# Critical: cwd must be readable by hermes. Bun inherits the invoker cwd and
# chdir()s into it before posix_spawn; if we stay in /home/user or /root,
# every child (git, true, …) fails with EACCES — looks like "bun cannot spawn".
gbrain_as_hermes() {
  runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" \
    ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY:-}" \
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    bash -c 'cd "$HOME" && exec gbrain "$@"' _ "$@"
}

# Pin sources.default.local_path in PGLite (config.json alone is not enough).
# Idempotent: no-op when already set to BRAIN_DIR.
ensure_default_source_path() {
  local want="${1:-$BRAIN_DIR}"
  local json
  json=$(gbrain_as_hermes sources list --json 2>/dev/null || true)
  if echo "$json" | grep -q "\"local_path\": *\"$want\""; then
    log "\"event\":\"source_path_ok\",\"path\":\"$want\""
    return 0
  fi
  local gb_mod="$HOME_DIR/.bun/install/global/node_modules/gbrain"
  local pin_script="$HOME_DIR/.gbrain/pin-default-source.ts"
  if [[ ! -d "$gb_mod" ]]; then
    log '"event":"source_path_pin_failed","reason":"gbrain_module_missing"'
    return 1
  fi
  cat >"$pin_script" <<PIN
import { createEngine } from "${gb_mod}/src/core/engine-factory.ts";
import { loadConfig } from "${gb_mod}/src/core/config.ts";
const path = process.argv[2] || "/home/hermes/brain";
const cfg = loadConfig();
if (!cfg) throw new Error("no gbrain config");
const engine = await createEngine(cfg as any);
await engine.connect(cfg as any);
await engine.executeRaw(
  \`UPDATE sources SET local_path = \$1 WHERE id = \$2\`,
  [path, "default"],
);
const rows = await engine.executeRaw(
  \`SELECT id, local_path FROM sources WHERE id = 'default'\`,
);
console.log(JSON.stringify(rows));
if (typeof (engine as any).close === "function") await (engine as any).close();
else if (typeof (engine as any).disconnect === "function") await (engine as any).disconnect();
PIN
  chown hermes:hermes "$pin_script" 2>/dev/null || true
  if runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" \
      bash -c 'cd "$HOME" && exec bun run "$@"' _ "$pin_script" "$want"
  then
    log "\"event\":\"source_path_pinned\",\"path\":\"$want\""
  else
    log "\"event\":\"source_path_pin_failed\",\"path\":\"$want\""
    return 1
  fi
}

# Prefer gbrain sync when source local_path is wired; fall back to shell put.
import_brain_markdown() {
  local root="$1"
  local count=0 fail=0
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' f; do
    local rel="${f#"$root"/}"
    local slug="${rel%.md}"
    # skip hidden paths
    [[ "$rel" == .* ]] && continue
    # Legacy whole-MEMORY dumps + archives; never re-import into PGLite.
    [[ "$rel" == hermes/inbox/* ]] && continue
    [[ "$rel" == hermes/inbox.archived*/* ]] && continue
    [[ "$rel" == hermes/inbox.archived*/*/* ]] && continue
    if gbrain_as_hermes put "$slug" <"$f" >>"$PUT_ERR" 2>&1; then
      count=$((count + 1))
    else
      fail=$((fail + 1))
      echo "{\"event\":\"brain_md_put_failed\",\"file\":\"$rel\",\"slug\":\"$slug\"}" >>"$PUT_ERR"
    fi
  done < <(find "$root" -type f -name '*.md' ! -path '*/.git/*' ! -path '*/hermes/inbox/*' ! -path '*/hermes/inbox.archived*/*' -print0 2>/dev/null)
  echo "{\"event\":\"brain_md_import\",\"imported\":$count,\"failed\":$fail,\"root\":\"$root\"}"
}

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

# Embedding keys: hermesEnv (/run/hermes.env) then agent .env (optional).
load_embed_keys() {
  local f
  for f in /run/hermes.env "$STATE/.env"; do
    [[ -f "$f" ]] || continue
    set -a
    # shellcheck disable=SC1090
    source <(grep -E '^(ZEROENTROPY_API_KEY|OPENAI_API_KEY)=' "$f" || true)
    set +a
  done
}
load_embed_keys

chown -R hermes:hermes "$HOME_DIR/.gbrain" "$HOME_DIR/brain" 2>/dev/null || true

# Ensure PGLite sources.default.local_path matches markdown brain (sync + doctor).
ensure_default_source_path "$BRAIN_DIR" || true

# Snapshot MEMORY/USER (audit only — do not re-import whole MEMORY into brain).
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

# MEMORY → hermes/inbox/* dumps RETIRED (2026-07-31).
# Dumping whole MEMORY.md via exclusive CLI raced gbrain serve and corrupted
# PGLite. Day-to-day durable writes = MCP put_page (main agent + gbrain-memory-flush
# nudge). Set GBRAIN_MEMORY_INBOX_DUMP=1 only for emergency backfill.
IMPORTED=0
FAILED=0
PENDING=0
PUT_ERR="$STATE/memories/export/last-put.err"
: >"$PUT_ERR"

if [[ "${GBRAIN_MEMORY_INBOX_DUMP:-0}" == "1" ]] && [[ -s "$STATE/memories/MEMORY.md" ]]; then
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
else
  echo "{\"event\":\"memory_inbox_dump_skipped\",\"reason\":\"retired_use_mcp_put_page\"}" >>"$PUT_ERR"
fi

# Probe PGLite before brain import.
if ! gbrain_as_hermes list -n 1 >>"$PUT_ERR" 2>&1; then
  if grep -qiE 'WASM|Aborted|already (instantiated|open)|multiple PGLite|failed to initialize' "$PUT_ERR" 2>/dev/null; then
    log '"error":"pglite_wasm_or_lock","hint":"PGLite single-writer/WASM class — exclusive gbrain doctor; backup brain.pglite; reinit-pglite only if doctor confirms damage (never auto-reinit). See workspace/GBRAIN.md"'
  else
    log '"error":"pglite_unavailable","hint":"gbrain doctor; if WASM Aborted, backup brain.pglite then gbrain reinit-pglite"'
  fi
  echo "--- last-put.err ---" >&2
  cat "$PUT_ERR" >&2 || true
  exit 7
fi

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

# Markdown brain: prefer gbrain sync (needs local_path + hermes-cwd); fall back to put.
BRAIN_MD_OK=null
SYNC_OK=null
if [[ -d "$BRAIN_DIR" ]]; then
  set +e
  gbrain_as_hermes sync --source default --no-embed >>"$PUT_ERR" 2>&1
  sync_ec=$?
  set -e
  if [[ "$sync_ec" -eq 0 ]]; then
    SYNC_OK=true
    BRAIN_MD_OK=true
    echo "{\"event\":\"brain_sync\",\"ok\":true}" | tee -a "$PUT_ERR"
  else
    SYNC_OK=false
    echo "{\"event\":\"brain_sync\",\"ok\":false,\"fallback\":\"import_brain_markdown\"}" | tee -a "$PUT_ERR"
    import_brain_markdown "$BRAIN_DIR" | tee -a "$PUT_ERR"
    BRAIN_MD_OK=true
  fi
else
  BRAIN_MD_OK=false
  SYNC_OK=false
  echo "{\"event\":\"brain_dir_missing\",\"path\":\"$BRAIN_DIR\"}" >>"$PUT_ERR"
fi

DREAM_OK=false
# --dir enables filesystem dream phases against the markdown checkout.
if gbrain_as_hermes dream --dir "$BRAIN_DIR" >>"$PUT_ERR" 2>&1 \
  || gbrain_as_hermes dream >>"$PUT_ERR" 2>&1; then
  DREAM_OK=true
fi

echo "{\"snapshot\":\"$SNAP\",\"inbox_pending\":$PENDING,\"inbox_imported\":$IMPORTED,\"inbox_failed\":$FAILED,\"brain_md\":$BRAIN_MD_OK,\"brain_sync\":$SYNC_OK,\"dream\":$DREAM_OK}"
log '"status":"complete"'

if [[ "$FAILED" -gt 0 || ( "$PENDING" -gt 0 && "$IMPORTED" -eq 0 ) ]]; then
  log '"error":"put_or_dream_failed","see":"'"$PUT_ERR"'"'
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
