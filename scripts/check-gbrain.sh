#!/usr/bin/env bash
# Static checks: GBrain wiring is MCP + reflex only (no exclusive CLI timers).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/hosts/system/hermes"
fail=0
pass() { echo "PASS $*"; }
fail_() { echo "FAIL $*"; fail=1; }

for f in gbrain.nix memory/AGENTS.md memory/registry.json memory/export-schema.json \
  BOOTSTRAP.md prompts/agents-gbrain.md prompts/gbrain-bootstrap-query.txt \
  scripts/gbrain-setup.sh reference/GBRAIN.md; do
  [ -f "$H/$f" ] && pass "present $f" || fail_ "missing $f"
done
grep -q 'gbrain-setup' "$ROOT/deploy" && pass "deploy gbrain-setup" || fail_ "deploy missing gbrain-setup"

grep -q 'mcpServers.gbrain' "$H/gbrain.nix" && pass "mcpServers.gbrain in gbrain.nix" || fail_ "no mcpServers.gbrain"
grep -q 'gbrain-mcp-http' "$H/gbrain.nix" && pass "gbrain-mcp-http unit" || fail_ "no gbrain-mcp-http"
grep -q 'url = gbrainMcpUrl\|3131/mcp' "$H/gbrain.nix" && pass "HTTP MCP url" || fail_ "no HTTP MCP url"
# Must not use per-agent stdio gbrain as primary (dual-writer class).
if grep -A15 'mcpServers.gbrain' "$H/gbrain.nix" | grep -qE 'command\s*='; then
  fail_ "mcpServers.gbrain still uses stdio command (use HTTP url)"
else
  pass "mcpServers.gbrain is HTTP (no stdio command)"
fi
grep -q 'gbrain.enable' "$H/gbrain.nix" && pass "gbrain.enable on composer (installs retrieval-reflex)" || fail_ "no composer gbrain hook"
# Static pointer index must be gone
if [ -e "$H/workspace/gbrain-pointer-index.json" ] || [ -d "$H/integrations/plugins/gbrain-reflex" ]; then
  fail_ "static gbrain-reflex / pointer-index still in tree"
else
  pass "static pointer workaround removed from tree"
fi
if grep -q 'GBRAIN_POINTER_INDEX' "$H/gbrain.nix"; then
  fail_ "GBRAIN_POINTER_INDEX still in gbrain.nix"
else
  pass "no GBRAIN_POINTER_INDEX"
fi

# Must NOT package exclusive CLI / nightly dream (disable/rm lines only OK).
if grep -E 'writeShellApplication|environment\.systemPackages' "$H/gbrain.nix" | grep -qE 'exclusive|nightly|consolidate|gbrain-dream|gbrain-embed'; then
  fail_ "gbrain.nix still packages exclusive CLI surface"
else
  pass "no exclusive CLI packaging in gbrain.nix"
fi

grep -q './gbrain.nix' "$H/default.nix" && pass "default.nix imports gbrain" || fail_ "gbrain not imported"
grep -q 'validate-gbrain' "$ROOT/deploy" && pass "deploy validate-gbrain" || fail_ "deploy missing validate-gbrain"
if grep -qE 'gbrain-consolidate|hermes-gbrain-consolidate' "$ROOT/deploy"; then
  fail_ "deploy still references gbrain-consolidate"
else
  pass "deploy has no gbrain-consolidate"
fi
# Obsolete exclusive scripts must not exist in tree
for dead in gbrain-exclusive-cli.sh hermes-gbrain-exclusive.sh hermes-gbrain-consolidate.sh \
  hermes-gbrain-dream.sh hermes-gbrain-embed.sh hermes-gbrain-nightly.sh; do
  if [ -e "$H/scripts/$dead" ]; then
    fail_ "obsolete script still present: scripts/$dead"
  fi
done
pass "exclusive CLI scripts removed from tree"

grep -q 'gbrain serve' "$H/BOOTSTRAP.md" && pass "BOOTSTRAP documents gbrain serve" || fail_ "BOOTSTRAP incomplete"
grep -qiE 'never shell|MCP only|MCP-only' "$H/memory/AGENTS.md" && pass "memory AGENTS MCP-only policy" || fail_ "memory AGENTS missing MCP-only"

if [ "$fail" -ne 0 ]; then
  echo "check-gbrain FAILED ($fail)"
  exit 1
fi
echo "check-gbrain OK"
