#!/usr/bin/env bash
# Hermes + G-Brain integration validation (run on hermes-01 as root/ops with docker).
# MCP + reflex only — no exclusive CLI / host dream timers.
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
docker exec "$CONTAINER" test -f /data/memory/registry.json && ok "container registry bind" || bad "container registry missing"

echo "=== 2. Legacy exclusive surface must be gone ==="
for u in hermes-gbrain-consolidate.timer gbrain-dream.timer gbrain-embed.timer gbrain-nightly.timer; do
  if systemctl is-enabled "$u" >/dev/null 2>&1; then
    bad "$u still enabled (should be purged)"
  else
    ok "$u not enabled"
  fi
done
for bin in hermes-gbrain-exclusive hermes-gbrain-consolidate hermes-gbrain-nightly hermes-gbrain-dream hermes-gbrain-embed; do
  if command -v "$bin" >/dev/null 2>&1 || [ -x "/run/current-system/sw/bin/$bin" ]; then
    bad "$bin still on PATH (exclusive CLI purged)"
  else
    ok "$bin not on PATH"
  fi
done
for f in /var/lib/hermes/bin/gbrain-exclusive-cli \
  /var/lib/hermes/bin/hermes-gbrain-consolidate \
  /var/lib/hermes/bin/hermes-gbrain-dream \
  /var/lib/hermes/bin/hermes-gbrain-embed; do
  if [ -e "$f" ]; then
    bad "agent-visible $f still present"
  else
    ok "purged $f"
  fi
done

echo "=== 3. gbrain-mcp-http (sole owner) + hermes-agent ==="
if systemctl is-active --quiet gbrain-mcp-http.service 2>/dev/null; then
  ok "gbrain-mcp-http active"
else
  bad "gbrain-mcp-http not active (sole PGLite owner)"
fi
if systemctl is-active --quiet hermes-agent.service 2>/dev/null; then
  ok "hermes-agent active"
else
  bad "hermes-agent not active"
fi
# Prefer one long-lived serve; warn on many.
nserve=$(pgrep -fc 'gbrain serve' 2>/dev/null || echo 0)
if [ "${nserve:-0}" -eq 1 ]; then
  ok "exactly one gbrain serve process"
elif [ "${nserve:-0}" -eq 0 ]; then
  bad "no gbrain serve process"
else
  warn "multiple gbrain serve processes ($nserve) — dual-writer risk; pkill orphans"
fi
if ss -ltn 2>/dev/null | grep -q ':3131'; then
  ok "gbrain HTTP listening :3131"
else
  warn "nothing listening on :3131"
fi

if [ -x /var/lib/hermes/home/.bun/bin/gbrain ] \
  || docker exec "$CONTAINER" test -x /home/hermes/.bun/bin/gbrain 2>/dev/null; then
  ok "gbrain CLI present (bun global)"
else
  warn "gbrain not installed (bootstrap: bun install -g github:garrytan/gbrain)"
fi

if [ -e /var/lib/hermes/workspace/gbrain-pointer-index.json ] \
  || [ -d /var/lib/hermes/plugins/gbrain-reflex ] \
  || [ -d /var/lib/hermes/.hermes/plugins/gbrain-reflex ]; then
  bad "static pointer index / gbrain-reflex still present (should be purged)"
else
  ok "static pointer workaround purged on live"
fi

for plug in gbrain-retrieval-reflex gbrain-memory-flush; do
  if docker exec "$CONTAINER" test -f "/data/.hermes/plugins/$plug/plugin.yaml" 2>/dev/null \
    || [ -f "/var/lib/hermes/.hermes/plugins/$plug/plugin.yaml" ]; then
    ok "plugin $plug installed under \$HERMES_HOME/plugins"
  else
    warn "plugin $plug not found under \$HERMES_HOME/plugins"
  fi
done

# Resolve IPC socket (ambient reflex) — present when gbrain serve + PGLite are healthy.
sock=""
for cand in \
  /var/lib/hermes/home/.gbrain/brain.pglite/.gbrain-resolve.sock \
  /home/hermes/.gbrain/brain.pglite/.gbrain-resolve.sock; do
  if [ -e "$cand" ]; then sock="$cand"; break; fi
done
if [ -n "$sock" ]; then
  ok "gbrain resolve IPC socket present ($sock)"
else
  warn "resolve IPC socket missing (serve not up, old gbrain, or non-PGLite path)"
fi

echo "=== 4. MCP list (gbrain expected) ==="
if command -v hermes >/dev/null 2>&1 || [ -x /run/current-system/sw/bin/hermes ]; then
  HERMES_BIN=$(command -v hermes 2>/dev/null || echo /run/current-system/sw/bin/hermes)
  if sudo -u hermes "$HERMES_BIN" mcp list 2>/dev/null | tee /tmp/hermes-mcp-list.txt | grep -qi gbrain; then
    ok "hermes mcp list includes gbrain"
  else
    warn "hermes mcp list missing gbrain (agent/OAuth/bootstrap?)"
    cat /tmp/hermes-mcp-list.txt 2>/dev/null | tail -20 || true
  fi
else
  warn "hermes CLI not on host PATH"
fi

echo "=== 5. Policy smoke (docs) ==="
if grep -qiE 'never shell|MCP only|HTTP' /var/lib/hermes/memory/AGENTS.md 2>/dev/null; then
  ok "MCP policy present in memory AGENTS.md"
else
  warn "memory AGENTS.md missing MCP policy wording"
fi
if [ -e /var/lib/hermes/workspace/GBRAIN.md ] || [ -e /var/lib/hermes/workspace/HERMES-WEBUI.md ]; then
  warn "stale host docs still under live workspace (should live in repo reference/ only)"
else
  ok "live workspace has no host GBRAIN/HERMES-WEBUI.md"
fi

echo "=== summary ==="
if [ "$fail" -eq 0 ]; then
  echo "PASS validate-gbrain-integration (MCP + reflex)"
  exit 0
else
  echo "FAIL validate-gbrain-integration ($fail checks)"
  exit 1
fi
