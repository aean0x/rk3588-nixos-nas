#!/usr/bin/env bash
# Structural checks for GBrain integration in this repo (shipped sources).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
H="$ROOT/hosts/system/hermes"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

for f in gbrain.nix memory/AGENTS.md memory/registry.json memory/export-schema.json \
  scripts/hermes-gbrain-consolidate-inner.sh scripts/hermes-gbrain-embed-inner.sh \
  BOOTSTRAP.md prompts/agents-gbrain.md; do
  [[ -f "$H/$f" ]] && pass "exists $f" || fail "missing $f"
done

grep -q 'mcpServers.gbrain' "$H/gbrain.nix" && pass "mcpServers.gbrain in gbrain.nix" || fail "no mcpServers.gbrain"
grep -q 'ZEROENTROPY_API_KEY' "$ROOT/secrets/sops.nix" && pass "ZEROENTROPY in sops hermesSecrets" || fail "missing ZEROENTROPY"
grep -q 'zeroentropy_api_key' "$ROOT/secrets/sops.nix" && pass "zeroentropy_api_key secret declared" || fail "secret not declared"
grep -q 'zeroentropy_api_key' "$ROOT/secrets/secrets.yaml" && pass "zeroentropy in secrets.yaml" || fail "not in secrets.yaml"
grep -q './gbrain.nix' "$H/default.nix" && pass "default.nix imports gbrain" || fail "gbrain not imported"
# SOUL activation disabled (comment-only mentions of hermes-soul are OK)
if grep -E '^\s*system\.activationScripts\.hermes-soul\s*=' "$H/default.nix" >/dev/null; then
  fail "SOUL activation still present in default.nix"
else
  pass "SOUL activation disabled"
fi
if grep -q 'soulMd\|writeText "hermes-soul' "$H/default.nix"; then
  fail "SOUL still packaged via soulMd writeText"
else
  pass "no soulMd packaging in default.nix"
fi
grep -q 'grok-4.5' "$H/default.nix" && pass "model default grok-4.5" || fail "missing grok-4.5"
grep -q 'xai-oauth' "$H/default.nix" && pass "provider xai-oauth" || fail "missing xai-oauth"
grep -q 'hermes-gbrain-consolidate' "$H/gbrain.nix" && pass "consolidate unit/script" || fail "no consolidate"
grep -q 'gbrain-embed' "$H/gbrain.nix" && pass "embed timer" || fail "no embed"
grep -q 'gbrain-dream' "$H/gbrain.nix" && pass "dream timer" || fail "no dream"
grep -q 'rocknas' "$H/memory/registry.json" && pass "registry deployment_id rocknas" || fail "registry still hermes-01"
grep -q 'validate-gbrain' "$ROOT/deploy" && pass "deploy validate-gbrain" || fail "deploy missing validate-gbrain"
grep -q 'gbrain serve' "$H/BOOTSTRAP.md" && pass "BOOTSTRAP documents gbrain serve" || fail "BOOTSTRAP incomplete"
grep -qi 'install.md\|install docs\|README install' "$H/BOOTSTRAP.md" && pass "BOOTSTRAP mentions upstream install docs" || fail "missing install.md prompt guidance"

[[ "$FAIL" -eq 0 ]] && { echo; echo "GBRAIN STRUCTURAL CHECK OK"; exit 0; }
echo; echo "GBRAIN STRUCTURAL CHECK FAILED"; exit 1
