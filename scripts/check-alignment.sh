#!/usr/bin/env bash
# Structural checks for Hermes NixOS declaration alignment.
# Asserts properties of the *shipped* sources — not reimplemented logic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES="$ROOT/hosts/system/hermes"
DEFAULT="$HERMES/default.nix"
RUNTIME="$HERMES/runtime.nix"
WEBUI="$HERMES/hermes-webui.nix"
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
require_file "$RUNTIME"
require_file "$WEBUI"
require_file "$HERMES/plugins.nix"
require_file "$HERMES/mcp.nix"
require_file "$SOPS"
require_file "$ROOT_AGENTS"
require_file "$HERMES_AGENTS"

if [[ -e "$HERMES/overrides/package-fix.nix" ]]; then
  fail "overrides/package-fix.nix leftover (composer owns the wrap)"
else
  pass "no leftover package-fix"
fi
if [[ -e "$HERMES/toolbox.nix" ]]; then
  fail "toolbox.nix leftover (composer owns toolbox)"
else
  pass "no leftover toolbox.nix"
fi
if [[ -d "$HERMES/integrations" ]]; then
  fail "integrations/ leftover (split into plugins.nix + mcp.nix)"
else
  pass "integrations/ removed"
fi

if grep -q 'inputs.hermes-pnp.nixosModules.default' "$DEFAULT" \
  && grep -q 'services.hermesPnP' "$DEFAULT"; then
  pass "default.nix imports hermes-pnp composer"
else
  fail "default.nix must import hermes-pnp.nixosModules.default and set hermesPnP"
fi

if grep -q 'github:aean0x/hermes-pnp' "$ROOT/flake.nix" \
  && ! grep -q 'feat/pnp-composer' "$ROOT/flake.nix"; then
  pass "flake input hermes-pnp tracks main"
else
  fail "flake.nix must pin github:aean0x/hermes-pnp (not feat/pnp-composer)"
fi

if grep -E '^\s*system\.activationScripts\.hermes-soul\s*=' "$DEFAULT" >/dev/null; then
  fail "SOUL activation should be disabled"
else
  pass "SOUL activation disabled (fresh agent)"
fi

if grep -q 'model-router' "$DEFAULT" \
  && grep -q 'git-hook' "$DEFAULT" \
  && grep -q 'HERMES_WEBUI_EXTENSION_DIR' "$WEBUI"; then
  pass "model-router + git-hook declared; WebUI extension wired"
else
  fail "missing model-router/git-hook or WebUI extension env"
fi

if grep -q 'projects-auto-commit' "$DEFAULT" "$HERMES/plugins.nix"; then
  fail "projects-auto-commit leftover (replaced by git-hook)"
else
  pass "no projects-auto-commit"
fi
if grep -q '/var/lib/hermes/bin/hermes-cli' "$ROOT/deploy"; then
  fail "deploy still calls leftover hermes-cli (use official hermes)"
else
  pass "deploy uses official hermes"
fi

if grep -q 'mcpServers.composio' "$HERMES/mcp.nix" \
  && grep -q 'services.mcpProxy' "$HERMES/mcp.nix" \
  && grep -q 'hermesPnP.mcpProxy.enable' "$HERMES/mcp.nix"; then
  pass "composio MCP client via hermes-pnp mcp-proxy"
else
  fail "missing composio → hermes-pnp mcp-proxy wiring"
fi

if grep -q 'proxyServices' "$WEBUI" \
  && grep -q 'cloudflareTunnel.proxyServices' "$WEBUI"; then
  pass "WebUI uses host Caddy + cloudflareTunnel proxyServices"
else
  fail "WebUI must use services.caddy.proxyServices + cloudflareTunnel.proxyServices"
fi

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

if [[ -f "$HERMES/gbrain.nix" ]] && [[ -f "$HERMES/memory/AGENTS.md" ]] && [[ -f "$HERMES/BOOTSTRAP.md" ]]; then
  pass "GBrain module + memory contract + BOOTSTRAP present"
else
  fail "missing GBrain docs/module surfaces"
fi

if grep -q 'gbrain.enable' "$HERMES/gbrain.nix"; then
  pass "gbrain.nix enables composer gbrain hook"
else
  fail "gbrain.nix must set services.hermesPnP.gbrain.enable"
fi

for opt in enable container settings extraDependencyGroups addToSystemPackages restart restartSec; do
  if grep -q "$opt" "$DEFAULT"; then
    :
  else
    fail "declaration missing expected option surface: $opt"
  fi
done
pass "core hermes-agent option surfaces present in default.nix"

if grep -q 'package.override' "$WEBUI"; then
  fail "webui must not override the agent package"
else
  pass "webui does not override agent package"
fi
if grep -q 'API_SERVER_' "$WEBUI"; then
  fail "webui still redeclares API_SERVER_* (belongs in sops hermes.env only)"
else
  pass "webui does not redeclare API_SERVER_*"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "ALIGNMENT CHECK FAILED"
  exit 1
fi
echo
echo "ALIGNMENT CHECK OK"
exit 0
