#!/usr/bin/env bash
# Static checks: GBrain wiring is MCP + reflex only (no exclusive CLI timers).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/hosts/system/hermes"
CONSUMER="$H/default.nix"
fail=0
pass() { echo "PASS $*"; }
fail_() { echo "FAIL $*"; fail=1; }

[ -f "$H/BOOTSTRAP.md" ] && pass "present BOOTSTRAP.md" || fail_ "missing BOOTSTRAP.md"
if [ -e "$H/modules/gbrain.nix" ]; then
  fail_ "modules/gbrain.nix leftover (HTTP + Bearer are hermes-pnp)"
else
  pass "no leftover modules/gbrain.nix"
fi
grep -q 'gbrain-setup' "$ROOT/deploy" && pass "deploy gbrain-setup" || fail_ "deploy missing gbrain-setup"

if [ -d "$H/memory" ]; then
  fail_ "hermes/memory leftover (unused registry pruned)"
else
  pass "no hermes/memory registry"
fi
if [ -e "$H/scripts/gbrain-setup.sh" ] || [ -e "$H/scripts/validate-gbrain-integration.sh" ]; then
  fail_ "gbrain setup/validate still vendored under hermes/scripts (belong in hermes-pnp)"
else
  pass "gbrain setup/validate not vendored on host"
fi
if [ -d "$H/prompts" ] || [ -d "$H/reference" ]; then
  fail_ "hermes/prompts or reference leftover (operator docs live in hermes-pnp)"
else
  pass "no leftover hermes prompts/reference"
fi
if grep -q 'hosts/system/hermes/scripts/gbrain-setup' "$ROOT/deploy" \
  || grep -q 'validate-gbrain-integration' "$ROOT/deploy"; then
  fail_ "deploy still copies host-vendored gbrain scripts"
else
  pass "deploy copies gbrain scripts from hermes-pnp"
fi

grep -q 'gbrain.enable' "$CONSUMER" && pass "gbrain.enable on composer" || fail_ "no composer gbrain hook"

if [ -e "$H/workspace/gbrain-pointer-index.json" ] || [ -d "$H/integrations/plugins/gbrain-reflex" ]; then
  fail_ "static gbrain-reflex / pointer-index still in tree"
else
  pass "static pointer workaround removed from tree"
fi
if grep -q 'GBRAIN_POINTER_INDEX' "$CONSUMER" "$H/runtime.nix"; then
  fail_ "GBRAIN_POINTER_INDEX still in consumer"
else
  pass "no GBRAIN_POINTER_INDEX"
fi

if grep -q './modules/gbrain.nix' "$CONSUMER"; then
  fail_ "default.nix still imports leftover modules/gbrain.nix"
else
  pass "default.nix does not import leftover gbrain module"
fi
grep -q 'validate-gbrain' "$ROOT/deploy" && pass "deploy validate-gbrain" || fail_ "deploy missing validate-gbrain"
if grep -qE 'gbrain-consolidate|hermes-gbrain-consolidate' "$ROOT/deploy"; then
  fail_ "deploy still references gbrain-consolidate"
else
  pass "deploy has no gbrain-consolidate"
fi
for dead in gbrain-exclusive-cli.sh hermes-gbrain-exclusive.sh hermes-gbrain-consolidate.sh \
  hermes-gbrain-dream.sh hermes-gbrain-embed.sh hermes-gbrain-nightly.sh; do
  if [ -e "$H/scripts/$dead" ]; then
    fail_ "obsolete script still present: scripts/$dead"
  fi
done
pass "exclusive CLI scripts removed from tree"

grep -q 'gbrain-setup' "$H/BOOTSTRAP.md" && pass "BOOTSTRAP documents gbrain-setup" || fail_ "BOOTSTRAP incomplete"
if grep -qiE 'never shell|MCP only|MCP-only' "$H/AGENTS.md"; then
  pass "hermes AGENTS MCP-only policy"
else
  fail_ "hermes AGENTS missing MCP-only"
fi

if [ "$fail" -ne 0 ]; then
  echo "check-gbrain FAILED ($fail)"
  exit 1
fi
echo "check-gbrain OK"
