#!/usr/bin/env bash
# Hermes + G-Brain integration validation (run on hermes-01 as root/ops with docker).
set -euo pipefail

fail=0
ok() { echo "OK  $*"; }
bad() { echo "FAIL $*"; fail=1; }
warn() { echo "WARN $*"; }

REGISTRY=/var/lib/hermes/memory/registry.json
AGENTS_MANIFEST=/var/lib/hermes/memory/AGENTS.md
HERMES_AGENTS=/var/lib/hermes/.hermes/AGENTS.md
CONTAINER=hermes-agent

echo "=== 1. agents.md + registry (look here first) ==="
[ -f "$AGENTS_MANIFEST" ] && ok "repo manifest $AGENTS_MANIFEST" || bad "missing repo manifest"
[ -f "$REGISTRY" ] && ok "registry $REGISTRY" || bad "missing registry"
if [ -f "$HERMES_AGENTS" ] && grep -q "look here first" "$HERMES_AGENTS"; then
  ok "live AGENTS.md contains look-here-first rule"
else
  bad "live AGENTS.md missing manifest rule"
fi
if diff -q "$AGENTS_MANIFEST" "$HERMES_AGENTS" >/dev/null 2>&1; then
  ok "AGENTS.md matches deployed manifest"
else
  bad "AGENTS.md differs from canonical memory manifest (fail-fast)"
fi
CANON_MEM=/var/lib/hermes/memory/AGENTS.md
if diff -q "$CANON_MEM" "$HERMES_AGENTS" >/dev/null 2>&1; then
  ok "live AGENTS.md matches registry canonical copy"
else
  bad "registry canonical AGENTS.md drift vs live .hermes copy"
fi
docker exec "$CONTAINER" test -f /data/memory/registry.json && ok "container registry bind" || bad "container registry missing"

echo "=== 2. Timers (hermes / gbrain / consolidate / memory) ==="
systemctl list-timers --all 2>/dev/null | grep -iE 'hermes-gbrain|gbrain-dream|gbrain-embed' && ok "integration timers listed" || warn "integration timers not installed yet"
for u in hermes-gbrain-consolidate.timer gbrain-dream.timer gbrain-embed.timer; do
  if systemctl is-enabled "$u" >/dev/null 2>&1; then
    systemctl is-active "$u" >/dev/null 2>&1 && ok "$u active" || warn "$u enabled but not active"
  fi
done
journalctl -u hermes-gbrain-consolidate.service -n 5 --no-pager 2>/dev/null | tail -3 || true

echo "=== 2b. Exclusive runner + systemd Conflicts (PGLite single-writer) ==="
if command -v hermes-gbrain-exclusive >/dev/null 2>&1 || [ -x /run/current-system/sw/bin/hermes-gbrain-exclusive ]; then
  ok "hermes-gbrain-exclusive on PATH"
else
  bad "hermes-gbrain-exclusive missing (deploy switch)"
fi
if [ -x /var/lib/hermes/bin/gbrain-exclusive-cli ]; then
  ok "gbrain-exclusive-cli installed under /var/lib/hermes/bin"
else
  bad "gbrain-exclusive-cli missing (activation install)"
fi
# Conflicts= must cross-link the three oneshots (cannot double-open PGLite).
for unit in hermes-gbrain-consolidate gbrain-dream gbrain-embed; do
  conf=$(systemctl show "${unit}.service" -p Conflicts --value 2>/dev/null || true)
  case "$unit" in
    hermes-gbrain-consolidate) need="gbrain-dream.service gbrain-embed.service" ;;
    gbrain-dream) need="hermes-gbrain-consolidate.service gbrain-embed.service" ;;
    gbrain-embed) need="hermes-gbrain-consolidate.service gbrain-dream.service" ;;
  esac
  missing=0
  for n in $need; do
    echo "$conf" | grep -qF "$n" || missing=1
  done
  if [ "$missing" -eq 0 ] && [ -n "$conf" ]; then
    ok "${unit}.service Conflicts= peers"
  else
    warn "${unit}.service Conflicts= incomplete or unit not installed: $conf"
  fi
done
# Guard must refuse while agent is up (no second PGLite writer).
if systemctl is-active --quiet hermes-agent.service 2>/dev/null; then
  if /var/lib/hermes/bin/gbrain-exclusive-cli list -n 1 >/tmp/gbrain-excl-cli.out 2>&1; then
    bad "gbrain-exclusive-cli ran while hermes-agent active (should refuse)"
  else
    if grep -qE 'pglite_busy|hermes_agent_active' /tmp/gbrain-excl-cli.out 2>/dev/null; then
      ok "gbrain-exclusive-cli refuses while agent active"
    else
      warn "gbrain-exclusive-cli failed while agent up (expected refuse); see /tmp/gbrain-excl-cli.out"
    fi
  fi
else
  warn "hermes-agent not active; skip exclusive-cli refuse check"
fi
# mcp-stderr: WASM / multi-instance → recovery hint only (never auto-reinit from validate).
MCP_ERR=/var/lib/hermes/.hermes/logs/mcp-stderr.log
if [ -f "$MCP_ERR" ] && grep -qiE 'WASM|Aborted|already (instantiated|open)|multiple PGLite|failed to initialize' "$MCP_ERR" 2>/dev/null; then
  warn "mcp-stderr shows PGLite/WASM class errors — soft stop/start agent; exclusive doctor; reinit only if doctor confirms (see workspace/GBRAIN.md). validate never auto-reinits."
else
  ok "mcp-stderr has no recent WASM/single-writer pattern (or log absent)"
fi

echo "=== 3. G-Brain startup path resolution ==="
docker exec -u hermes "$CONTAINER" bash -lc '
  export HERMES_MEMORY_REGISTRY=/data/memory/registry.json
  test -f "$HERMES_MEMORY_REGISTRY" || exit 3
  jq -r ".hermes_memory.builtin_profile.memory_md.container, .gbrain_memory.pglite_data.container" "$HERMES_MEMORY_REGISTRY"
' | while read -r line; do ok "gbrain registry path: $line"; done

echo "=== 4. Manual consolidation dry path ==="
if [ -x /run/current-system/sw/bin/hermes-gbrain-consolidate ]; then
  if /run/current-system/sw/bin/hermes-gbrain-consolidate 2>&1 | tee /tmp/consolidate-last.jsonl | grep -q '"inbox_imported"'; then
    ok "consolidation produced snapshot log"
  else
    warn "consolidation did not complete (check export dir perms / journal)"
  fi
else
  warn "hermes-gbrain-consolidate not on PATH (deploy switch first)"
fi

echo "=== 5. G-Brain query freshness (smoke) ==="
docker exec -u hermes "$CONTAINER" bash -lc 'gbrain list -n 3 2>&1' | head -5 && ok "gbrain list" || warn "gbrain list failed"

echo "=== 6. Config drift (registry vs live paths) ==="
H_MEM=$(jq -r .hermes_memory.builtin_profile.memory_md.host "$REGISTRY")
[ -f "$H_MEM" ] && ok "registry memory_md exists on host" || warn "MEMORY.md not yet created"
G_PG=$(jq -r .gbrain_memory.pglite_data.host "$REGISTRY")
[ -d "$G_PG" ] && ok "gbrain pglite dir on host" || bad "gbrain pglite missing"

echo "=== 7. Namespace isolation ==="
[ "$(jq -r .namespace_isolation.cross_user_forbidden "$REGISTRY")" = "true" ] && ok "cross_user_forbidden in registry" || bad "namespace policy"

echo "=== 8. Fault injection (rename export dir) ==="
if docker exec "$CONTAINER" test -d /data/.hermes/memories/export/inbox; then
  docker exec -u hermes "$CONTAINER" bash -lc 'mv /data/.hermes/memories/export/inbox /data/.hermes/memories/export/inbox.bak 2>/dev/null || true'
  if docker exec -u hermes "$CONTAINER" bash -lc 'test -d /data/.hermes/memories/export/inbox' 2>/dev/null; then
    bad "fault injection did not hide inbox"
  else
    ok "inbox hidden for fault test"
    docker exec -u hermes "$CONTAINER" bash -lc 'mv /data/.hermes/memories/export/inbox.bak /data/.hermes/memories/export/inbox 2>/dev/null || mkdir -p /data/.hermes/memories/export/inbox'
    ok "inbox restored"
  fi
fi

echo "=== 9. Concurrent soak (exclusive flock serializes consolidate) ==="
if [ "${SKIP_CONCURRENT_SOAK:-}" != 1 ] && [ -x /run/current-system/sw/bin/hermes-gbrain-consolidate ]; then
  /run/current-system/sw/bin/hermes-gbrain-consolidate >/tmp/consolidate-a.jsonl 2>&1 &
  PID_A=$!
  /run/current-system/sw/bin/hermes-gbrain-consolidate >/tmp/consolidate-b.jsonl 2>&1 &
  PID_B=$!
  wait "$PID_A" "$PID_B" || true
  SERIAL=0
  grep -qE 'exclusive_lock_acquired|delegating_to_exclusive_runner|consolidation_lock_held' /tmp/consolidate-a.jsonl /tmp/consolidate-b.jsonl 2>/dev/null && SERIAL=1
  # Second run should wait on flock then proceed, or one may timeout — both must not open PGLite together.
  if [ "$SERIAL" -eq 1 ]; then
    ok "parallel consolidate: exclusive runner path exercised"
  else
    warn "parallel consolidate: expected exclusive lock logs (check /tmp/consolidate-*.jsonl)"
  fi
else
  warn "concurrent soak skipped"
fi

echo "=== 10. Inbox import + query probe ==="
if grep -qF 'integration-probe:' /var/lib/hermes/.hermes/memories/MEMORY.md 2>/dev/null; then
  ok "MEMORY.md integration probe present"
else
  warn "integration probe missing (redeploy for activation seed)"
fi
if [ -x /run/current-system/sw/bin/hermes-gbrain-consolidate ]; then
  /run/current-system/sw/bin/hermes-gbrain-consolidate 2>&1 | tee /tmp/consolidate-probe.jsonl >/dev/null
  LAST=$(grep '"inbox_imported"' /tmp/consolidate-probe.jsonl | tail -1 || true)
  echo "$LAST" | grep -q '"inbox_imported":' && ok "consolidation json has inbox_imported" || warn "consolidation output unexpected"
  if echo "$LAST" | grep -qE '"inbox_imported":([1-9][0-9]*)'; then
    ok "inbox_imported >= 1"
  elif echo "$LAST" | grep -q '"skipped":true'; then
    warn "consolidation skipped (lock held); inbox_imported not exercised"
  else
    warn "inbox_imported still 0 (no pending inbox json or put failed)"
  fi
fi
docker exec "$CONTAINER" pkill -f 'gbrain serve' 2>/dev/null || true
sleep 2
docker exec -u hermes "$CONTAINER" bash -lc 'gbrain list -n 5 2>&1 | head -8' >/tmp/gbrain-list.txt 2>&1 && ok "gbrain list after consolidate" || warn "gbrain list failed (PGLite lock?)"

echo "=== 11. Snapshot checksum integrity (post-consolidate) ==="
SNAP_ROOT=/var/lib/hermes/.hermes/memories/export/snapshots
LATEST_SNAP=$(find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
if [ -n "$LATEST_SNAP" ] && [ -f "$LATEST_SNAP/MEMORY.md.sha256" ]; then
  (cd "$LATEST_SNAP" && sha256sum -c MEMORY.md.sha256 >/dev/null 2>&1) && ok "latest snapshot MEMORY.md checksum" || warn "snapshot checksum mismatch (stale snapshot dir?)"
else
  warn "no snapshot with MEMORY.md.sha256 yet"
fi

echo "=== 12. Restore drill (optional RESTORE_DRILL=1) ==="
if [ "${RESTORE_DRILL:-}" = 1 ]; then
  warn "restore drill is manual: point registry at alternate snapshot, redeploy, re-consolidate, compare query"
else
  warn "restore drill not run (set RESTORE_DRILL=1 to document operator path)"
fi

echo "=== 13. gbrain-reflex plugin + retrieval-reflex skill + pointer index ==="
PLUGIN_HOME=/var/lib/hermes/.hermes/plugins/gbrain-reflex
PLUGIN_EXT=/var/lib/hermes/plugins/gbrain-reflex
INDEX=/var/lib/hermes/workspace/gbrain-pointer-index.json
SKILL=/var/lib/hermes/skills/retrieval-reflex/SKILL.md
GBRAIN_MD=/var/lib/hermes/workspace/GBRAIN.md
CFG=/var/lib/hermes/.hermes/config.yaml

if [ -f "$PLUGIN_HOME/plugin.yaml" ] && [ -f "$PLUGIN_HOME/__init__.py" ]; then
  ok "plugin present at $PLUGIN_HOME"
elif [ -f "$PLUGIN_EXT/plugin.yaml" ] && [ -f "$PLUGIN_EXT/__init__.py" ]; then
  ok "plugin present at $PLUGIN_EXT"
else
  bad "gbrain-reflex plugin missing under .hermes/plugins or plugins/"
fi
if [ -f "$PLUGIN_HOME/plugin.yaml" ] || [ -f "$PLUGIN_EXT/plugin.yaml" ]; then
  if grep -q 'pre_llm_call' "$PLUGIN_HOME/plugin.yaml" 2>/dev/null \
    || grep -q 'pre_llm_call' "$PLUGIN_EXT/plugin.yaml" 2>/dev/null; then
    ok "plugin declares pre_llm_call"
  else
    bad "plugin.yaml missing pre_llm_call"
  fi
fi
[ -f "$SKILL" ] && grep -q 'retrieval-reflex' "$SKILL" && ok "retrieval-reflex skill present" \
  || bad "missing retrieval-reflex skill at $SKILL"
[ -f "$INDEX" ] && grep -q 'ops/gbrain-protocol' "$INDEX" && ok "pointer index present" \
  || bad "missing or incomplete pointer index at $INDEX"
if [ -f "$GBRAIN_MD" ] && grep -q 'Proactive pointers' "$GBRAIN_MD"; then
  ok "GBRAIN.md documents proactive pointers"
else
  bad "GBRAIN.md missing Proactive pointers section"
fi
if [ -f "$CFG" ]; then
  if grep -qE 'gbrain-reflex' "$CFG"; then
    ok "config.yaml mentions gbrain-reflex (enabled allow-list greppable)"
  else
    warn "config.yaml has no gbrain-reflex string (check plugins.enabled after activate)"
  fi
  if grep -qE 'plugins:' "$CFG" && grep -qE 'enabled:' "$CFG"; then
    ok "config.yaml has plugins/enabled keys"
  else
    warn "config.yaml plugins.enabled not greppable yet"
  fi
else
  warn "config.yaml missing (gateway not set up yet)"
fi
if docker exec "$CONTAINER" test -f /data/workspace/gbrain-pointer-index.json 2>/dev/null; then
  ok "container sees pointer index bind"
else
  warn "container pointer index path missing (container down or not activated)"
fi

if [ "$fail" -eq 0 ]; then
  echo "=== INTEGRATION CHECKS PASSED (see WARN for optional items) ==="
else
  echo "=== INTEGRATION CHECKS FAILED ==="
  exit 1
fi
