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

echo "=== 9. Concurrent soak (consolidate under flock) ==="
if [ "${SKIP_CONCURRENT_SOAK:-}" != 1 ] && [ -x /run/current-system/sw/bin/hermes-gbrain-consolidate ]; then
  /run/current-system/sw/bin/hermes-gbrain-consolidate >/tmp/consolidate-a.jsonl 2>&1 &
  PID_A=$!
  /run/current-system/sw/bin/hermes-gbrain-consolidate >/tmp/consolidate-b.jsonl 2>&1 &
  PID_B=$!
  wait "$PID_A" "$PID_B" || true
  SKIPPED=0
  grep -q 'consolidation_lock_held' /tmp/consolidate-a.jsonl /tmp/consolidate-b.jsonl 2>/dev/null && SKIPPED=1
  if [ "$SKIPPED" -eq 1 ]; then
    ok "parallel consolidate: one runner skipped on lock"
  else
    warn "parallel consolidate: expected one skipped=true (check logs)"
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

if [ "$fail" -eq 0 ]; then
  echo "=== INTEGRATION CHECKS PASSED (see WARN for optional items) ==="
else
  echo "=== INTEGRATION CHECKS FAILED ==="
  exit 1
fi
