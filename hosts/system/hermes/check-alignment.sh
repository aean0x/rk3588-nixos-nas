#!/usr/bin/env bash
# Structural checks for Hermes NixOS declaration alignment.
# Asserts properties of the *shipped* sources (default.nix, dashboard.nix,
# secrets/sops.nix, AGENTS.md paths, gap list) — not reimplemented logic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERMES="$ROOT/hosts/system/hermes"
DEFAULT="$HERMES/default.nix"
DASHBOARD="$HERMES/dashboard.nix"
SOPS="$ROOT/secrets/sops.nix"
ROOT_AGENTS="$ROOT/AGENTS.md"
HERMES_AGENTS="$HERMES/AGENTS.md"
FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

require_file() {
  if [[ -f "$1" ]]; then pass "exists $1"
  else fail "missing $1"
  fi
}

require_file "$DEFAULT"
require_file "$DASHBOARD"
require_file "$SOPS"
require_file "$ROOT_AGENTS"
require_file "$HERMES_AGENTS"

# --- declaration: no Docker -p publish (module uses --network=host) ---
if grep -E '^\s*"-p"' "$DEFAULT" >/dev/null 2>&1; then
  fail "default.nix still publishes ports with -p (ignored under host network)"
else
  pass "default.nix has no -p port publish under container.extraOptions"
fi

if grep -q '127.0.0.1:9119:9119' "$DEFAULT"; then
  fail "default.nix still maps 9119 via bridge-style publish"
else
  pass "default.nix does not bridge-map 9119"
fi

# Resource limits still present
if grep -q -- '--memory=4g' "$DEFAULT" && grep -q -- '--cpus=2' "$DEFAULT"; then
  pass "container resource limits retained"
else
  fail "container resource limits missing from extraOptions"
fi

# --- dashboard comments must not reintroduce port-mapping drift ---
# Module hardcodes --network=host; -p publish is ignored. Comments that claim
# "docker port mapping" / bridge-style host:container publish are criterion-2 drift.
if grep -qiE 'port mapping|docker port|127\.0\.0\.1:9119:9119' "$DASHBOARD"; then
  fail "dashboard.nix still claims docker port mapping / bridge publish for :9119"
else
  pass "dashboard.nix does not claim docker port mapping for :9119"
fi

if grep -qiE 'network=host|host network|host namespace' "$DASHBOARD"; then
  pass "dashboard.nix documents host-network binding"
else
  fail "dashboard.nix missing host-network explanation (module hardcodes --network=host)"
fi

# --- dependency groups: messaging required; web not required (in [all]) ---
if grep -q '"messaging"' "$DEFAULT"; then
  pass "extraDependencyGroups includes messaging"
else
  fail "extraDependencyGroups missing messaging"
fi

# Extract the extraDependencyGroups list block and ensure "web" is not listed
groups_block=$(awk '/extraDependencyGroups = \[/,/\];/' "$DEFAULT")
if echo "$groups_block" | grep -q '"web"'; then
  fail "extraDependencyGroups still lists web (already in hermes [all])"
else
  pass "extraDependencyGroups does not redundantly list web"
fi

# --- HA env var names match Hermes HASS_* ---
if grep -q 'HASS_TOKEN' "$SOPS" && grep -q 'HASS_URL' "$SOPS"; then
  pass "hermesSecrets maps HASS_TOKEN and HASS_URL"
else
  fail "hermesSecrets missing HASS_TOKEN/HASS_URL"
fi

# Ensure obsolete HA_* env names are not used for hermesSecrets block
hermes_block=$(awk '/hermesSecrets = \{/,/^  \};/' "$SOPS")
if echo "$hermes_block" | grep -E '^\s+HA_TOKEN|^\s+HA_URL' >/dev/null; then
  fail "hermesSecrets still uses HA_TOKEN/HA_URL (Hermes expects HASS_*)"
else
  pass "hermesSecrets no longer uses HA_TOKEN/HA_URL env names"
fi

# --- SOUL: declarative install disabled (fresh agent + GBrain era) ---
if grep -E '^\s*system\.activationScripts\.hermes-soul\s*=' "$DEFAULT" >/dev/null; then
  fail "SOUL activation should be disabled"
else
  pass "SOUL activation disabled (fresh agent)"
fi

MR="$HERMES/integrations/plugins/model-router/__init__.py"
if [[ -f "$MR" ]]; then
  # Fail only on actual write paths, not docstrings that say we don't touch SOUL.
  if grep -nE 'SOUL\.md' "$MR" \
    | grep -viE 'does not|must not|no .*SOUL|without.*SOUL|not (write|touch|edit)' \
    | grep -qE 'write|open\(|Path\(|put_page|SOUL\.md["'\'']'; then
    fail "model-router must not write SOUL.md"
  else
    pass "model-router does not touch SOUL.md"
  fi
  if grep -q 'model-router' "$HERMES/integrations/default.nix" \
    && grep -q 'HERMES_WEBUI_EXTENSION_DIR' "$HERMES/hermes-webui.nix" \
    && grep -q 'integrations' "$DEFAULT"; then
    pass "model-router in integrations + WebUI extension + default.nix import"
  else
    fail "model-router missing from integrations or WebUI extension env"
  fi
  if [[ -f "$HERMES/integrations/mcp/maton.nix" ]] && [[ -f "$HERMES/integrations/mcp/maton-mcp.sh" ]]; then
    pass "maton MCP client under integrations/mcp"
  else
    fail "missing integrations/mcp/maton.nix or maton-mcp.sh"
  fi
else
  fail "missing hosts/system/hermes/integrations/plugins/model-router/__init__.py"
fi

# --- project path docs: no stale services/hermes.nix ---
if grep -n 'services/hermes\.nix' "$ROOT_AGENTS" "$HERMES_AGENTS" 2>/dev/null; then
  fail "docs still reference stale path services/hermes.nix"
else
  pass "docs do not claim services/hermes.nix"
fi

if grep -q 'hosts/system/hermes' "$ROOT_AGENTS" || grep -q 'hermes/' "$ROOT_AGENTS"; then
  pass "root AGENTS.md points at hermes/ tree"
else
  fail "root AGENTS.md missing hermes/ path"
fi

# --- dashboard: custom unit still proxies via caddy ---
if grep -q 'hermes-dashboard' "$DASHBOARD" && grep -q 'proxyServices."hermes' "$DASHBOARD"; then
  pass "dashboard unit + caddy proxy present"
else
  fail "dashboard.nix missing service or caddy proxy"
fi
if grep -q 'proxyUpstreamHost."hermes' "$DASHBOARD" && grep -q 'proxyUpstreamHost' "$ROOT/hosts/system/services/caddy.nix"; then
  pass "dashboard Host rewrite (proxyUpstreamHost) wired for loopback guard"
else
  fail "missing caddy proxyUpstreamHost for hermes dashboard (Invalid Host class)"
fi

# --- GBrain contract docs (supersede old high-value gap list) ---
if [[ -f "$HERMES/gbrain.nix" ]] && [[ -f "$HERMES/memory/AGENTS.md" ]] && [[ -f "$HERMES/BOOTSTRAP.md" ]]; then
  pass "GBrain module + memory contract + BOOTSTRAP present"
else
  fail "missing GBrain docs/module surfaces"
fi

# --- known module options we set exist as identifiers in default.nix ---
for opt in enable container environmentFiles settings mcpServers extraDependencyGroups addToSystemPackages restart restartSec; do
  if grep -q "$opt" "$DEFAULT"; then
    :
  else
    fail "declaration missing expected option surface: $opt"
  fi
done
pass "core hermes-agent option surfaces present in default.nix"

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "ALIGNMENT CHECK FAILED"
  exit 1
fi

echo
echo "ALIGNMENT CHECK OK (gbrain-era; SOUL off)"
exit 0
