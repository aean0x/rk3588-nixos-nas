#!/usr/bin/env bash
# Structural checks for Hermes NixOS declaration alignment.
# Asserts properties of the *shipped* sources — not reimplemented logic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES="$ROOT/hosts/system/hermes"
DEFAULT="$HERMES/default.nix"
RUNTIME="$HERMES/runtime.nix"
WEBUI="$HERMES/hermes-webui.nix"
PKGFIX="$HERMES/overrides/package-fix.nix"
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
require_file "$PKGFIX"
require_file "$HERMES/integrations/hmc.nix"
require_file "$SOPS"

if [[ -e "$HERMES/context-manager.nix" ]]; then
  fail "context-manager.nix still present (HMC is integrations/hmc.nix)"
else
  pass "HMC folded into integrations (no context-manager.nix)"
fi
require_file "$ROOT_AGENTS"
require_file "$HERMES_AGENTS"

# --- dashboard decommissioned ---
if [[ -e "$HERMES/dashboard.nix" ]]; then
  fail "dashboard.nix still present (decommissioned; WebUI is the UI)"
else
  pass "dashboard.nix removed"
fi
if grep -q 'hermes-dashboard\|./dashboard.nix' "$DEFAULT" "$WEBUI" "$HERMES_AGENTS" 2>/dev/null; then
  fail "hermes-dashboard still referenced in live hermes modules/docs"
else
  pass "no hermes-dashboard references in hermes modules/docs"
fi
if grep -q '9119' "$DEFAULT" "$WEBUI"; then
  fail "gateway/webui still mention dashboard port 9119"
else
  pass "no leftover :9119 in gateway/webui"
fi

# --- declaration: no Docker -p publish (module uses --network=host) ---
if grep -E '^\s*"-p"' "$DEFAULT" >/dev/null 2>&1; then
  fail "default.nix still publishes ports with -p (ignored under host network)"
else
  pass "default.nix has no -p port publish under container.extraOptions"
fi

# Resource caps live in runtime.nix and are consumed by both entrypoints
if grep -q 'contextLimit = 200000' "$RUNTIME" \
  && grep -q 'context_length = hermes.contextLimit' "$DEFAULT"; then
  pass "200k contextLimit SoT wired to model.context_length"
else
  fail "runtime.nix contextLimit / model.context_length missing"
fi

if grep -q 'memoryDocker = "2g"' "$RUNTIME" \
  && grep -q 'cpus = 2' "$RUNTIME" \
  && grep -q 'containerResourceOptions' "$DEFAULT" \
  && grep -q 'systemdResourceConfig' "$WEBUI"; then
  pass "shared 2G/2cpu resource map wired to gateway + WebUI"
else
  fail "runtime.nix 2G map not wired to both entrypoints"
fi

# --- dependency groups: messaging required; web not required (in [all]) ---
if grep -q '"messaging"' "$DEFAULT"; then
  pass "extraDependencyGroups includes messaging"
else
  fail "extraDependencyGroups missing messaging"
fi

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

hermes_block=$(awk '/hermesSecrets = \{/,/^  \};/' "$SOPS")
if echo "$hermes_block" | grep -E '^\s+HA_TOKEN|^\s+HA_URL' >/dev/null; then
  fail "hermesSecrets still uses HA_TOKEN/HA_URL (Hermes expects HASS_*)"
else
  pass "hermesSecrets no longer uses HA_TOKEN/HA_URL env names"
fi

if grep -q 'hermesWebuiEnv\|hermes-webui.env' "$SOPS"; then
  fail "sops still declares vestigial /run/hermes-webui.env"
else
  pass "no hermes-webui.env sops template"
fi

# --- SOUL: declarative install disabled (fresh agent + GBrain era) ---
if grep -E '^\s*system\.activationScripts\.hermes-soul\s*=' "$DEFAULT" >/dev/null; then
  fail "SOUL activation should be disabled"
else
  pass "SOUL activation disabled (fresh agent)"
fi

MR="$HERMES/integrations/plugins/model-router/__init__.py"
if [[ -f "$MR" ]]; then
  if grep -nE 'SOUL\.md' "$MR" \
    | grep -viE 'does not|must not|no .*SOUL|without.*SOUL|not (write|touch|edit)' \
    | grep -qE 'write|open\(|Path\(|put_page|SOUL\.md["'\'']'; then
    fail "model-router must not write SOUL.md"
  else
    pass "model-router does not touch SOUL.md"
  fi
  if grep -q 'model-router' "$HERMES/integrations/default.nix" \
    && grep -q 'HERMES_WEBUI_EXTENSION_DIR' "$WEBUI" \
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

for opt in enable container environmentFiles settings mcpServers extraDependencyGroups addToSystemPackages restart restartSec; do
  if grep -q "$opt" "$DEFAULT"; then
    :
  else
    fail "declaration missing expected option surface: $opt"
  fi
done
pass "core hermes-agent option surfaces present in default.nix"

if grep -q 'extraDependencyGroups = agentCfg.extraDependencyGroups' "$PKGFIX" \
  && grep -q '_module.args.hermesRuntimeEnv' "$PKGFIX"; then
  pass "package-fix bakes service extras and exports hermesRuntimeEnv"
else
  fail "package-fix must bake extraDependencyGroups and export hermesRuntimeEnv"
fi
if grep -q 'agent.package = agentPkg' "$WEBUI" \
  && ! grep -q 'package.override' "$WEBUI"; then
  pass "webui consumes services.hermes-agent.package without override"
else
  fail "webui must use agent.package = cfg.package (no extras override)"
fi
if grep -q 'hermesRuntimeEnv' "$WEBUI" \
  && grep -q 'environmentFiles = config.services.hermes-agent.environmentFiles' "$WEBUI"; then
  pass "webui inherits hermesRuntimeEnv + agent environmentFiles"
else
  fail "webui must inherit hermesRuntimeEnv and agent environmentFiles"
fi
if grep -q 'API_SERVER_' "$WEBUI"; then
  fail "webui still redeclares API_SERVER_* (belongs in sops hermes.env only)"
else
  pass "webui does not redeclare API_SERVER_*"
fi
if grep -q 'extraPackages' "$HERMES/toolbox.nix"; then
  fail "toolbox.nix still sets unused extraPackages (container mode)"
else
  pass "toolbox.nix has no unused extraPackages"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "ALIGNMENT CHECK FAILED"
  exit 1
fi

echo
echo "ALIGNMENT CHECK OK (gbrain-era; SOUL off; dashboard gone)"
exit 0
