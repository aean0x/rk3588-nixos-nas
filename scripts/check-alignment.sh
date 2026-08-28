#!/usr/bin/env bash
# Structural checks for Hermes NixOS declaration alignment.
# Asserts properties of the *shipped* sources — not reimplemented logic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES="$ROOT/hosts/system/hermes"
CONSUMER="$HERMES/default.nix"
RUNTIME="$HERMES/runtime.nix"
COMPOSIO="$HERMES/modules/composio.nix"
BANKSYNC="$HERMES/modules/banksync.nix"
OPENBANKING="$HERMES/modules/open-banking.nix"
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

require_file "$CONSUMER"
require_file "$RUNTIME"
require_file "$COMPOSIO"
require_file "$BANKSYNC"
require_file "$OPENBANKING"
require_file "$HERMES/modules/onedrive.nix"
require_file "$SOPS"
require_file "$ROOT_AGENTS"
require_file "$HERMES_AGENTS"
if [[ -e "$HERMES/modules/gbrain.nix" ]]; then
  fail "modules/gbrain.nix leftover (HTTP + Bearer are hermes-pnp)"
else
  pass "no leftover modules/gbrain.nix"
fi
if [[ -e "$HERMES/modules/workstation.nix" ]] || [[ -d "$HERMES/skills/workstation" ]]; then
  fail "workstation leftover (sunset)"
else
  pass "workstation checkout/ssh gone"
fi

if [[ -e "$ROOT/hosts/system/services/hermes.nix" ]]; then
  fail "hosts/system/services/hermes.nix leftover (consumer is hermes/default.nix)"
else
  pass "no services/hermes.nix"
fi
if [[ -e "$HERMES/hermes.nix" ]]; then
  fail "hermes/hermes.nix leftover (consumer is hermes/default.nix)"
else
  pass "no hermes/hermes.nix"
fi
if [[ -e "$HERMES/browser.nix" ]]; then
  fail "browser.nix leftover (composer owns browser)"
else
  pass "no leftover browser.nix"
fi
if [[ -e "$HERMES/plugins.nix" ]]; then
  fail "plugins.nix leftover (HMC is hermesPnP.hmc)"
else
  pass "no leftover plugins.nix"
fi
if [[ -e "$HERMES/mcp.nix" ]] || [[ -e "$HERMES/gbrain.nix" ]] || [[ -e "$HERMES/onedrive.nix" ]] || [[ -e "$HERMES/workstation.nix" ]] || [[ -e "$HERMES/hermes-webui.nix" ]]; then
  fail "old hermes/*.nix leftovers (moved to default.nix / modules/)"
else
  pass "old hermes/*.nix moved"
fi
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
  fail "integrations/ leftover"
else
  pass "integrations/ removed"
fi
if [[ -e "$HERMES/workspace/soul.md" ]]; then
  fail "workspace/soul.md leftover (SOUL not declarative)"
else
  pass "no soul.md"
fi
if [[ -d "$HERMES/skills" ]]; then
  fail "hermes/skills leftover (workstation sunset; first-party skills in hermes-pnp)"
else
  pass "no host hermes/skills"
fi

if grep -q 'inputs.hermes-pnp.nixosModules.default' "$CONSUMER" \
  && grep -q 'services.hermesPnP' "$CONSUMER"; then
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

if grep -E '^\s*system\.activationScripts\.hermes-soul\s*=' "$CONSUMER" >/dev/null; then
  fail "SOUL activation should be gone"
else
  pass "no SOUL activation"
fi

if grep -q 'model-router' "$CONSUMER" \
  && grep -q 'git-hook' "$CONSUMER"; then
  pass "model-router + git-hook declared (WebUI extension is composer pairing)"
else
  fail "missing model-router/git-hook"
fi
if grep -qE '^[[:space:]]*model\.context_length[[:space:]]*=' "$CONSUMER"; then
  fail "consumer sets model.context_length (stamps every model; use compression.threshold_tokens)"
else
  pass "no global model.context_length"
fi
if grep -qE '^[[:space:]]*max_turns[[:space:]]*=' "$CONSUMER"; then
  fail "consumer pins max_turns (upstream default is unlimited)"
else
  pass "no consumer max_turns"
fi
if grep -q 'deepseek-v4-pro' "$CONSUMER" \
  && grep -q 'fallback_model' "$CONSUMER"; then
  pass "fallback_model is deepseek-v4-pro"
else
  fail "consumer must set fallback_model to deepseek-v4-pro"
fi
if grep -qE 'services\.hermes-webui\s*=' "$CONSUMER"; then
  fail "default.nix still declares services.hermes-webui (composer pairs it)"
else
  pass "WebUI pairing left to hermes-pnp"
fi

if grep -q 'hmc.enable' "$CONSUMER"; then
  pass "HMC declared via hermesPnP.hmc"
else
  fail "default.nix must set services.hermesPnP.hmc.enable"
fi

if grep -qE 'extraSkills\.workstation|checkout-workstation|ssh-workstation|nix_pc_agent_ssh_key' \
  "$CONSUMER" "$RUNTIME" "$COMPOSIO" "$SOPS" "$ROOT_AGENTS" "$HERMES_AGENTS" "$HERMES/BOOTSTRAP.md"; then
  fail "workstation checkout/ssh still referenced"
else
  pass "no workstation checkout/ssh references"
fi

if grep -q 'container.enable' "$CONSUMER"; then
  pass "container.enable declared on hermesPnP"
else
  fail "default.nix must set services.hermesPnP.container.enable"
fi

if grep -q 'projects-auto-commit' "$CONSUMER" "$COMPOSIO"; then
  fail "projects-auto-commit leftover (replaced by git-hook)"
else
  pass "no projects-auto-commit"
fi
if grep -q '/var/lib/hermes/bin/hermes-cli' "$ROOT/deploy"; then
  fail "deploy still calls leftover hermes-cli (use official hermes)"
else
  pass "deploy uses official hermes"
fi

if grep -q 'mcpServers.composio' "$COMPOSIO" \
  && grep -q 'hermesPnP.mcpProxy.backends' "$COMPOSIO"; then
  pass "composio MCP client via hermesPnP.mcpProxy.backends"
else
  fail "missing composio → hermesPnP.mcpProxy.backends wiring"
fi
if grep -q 'mcpProxy.enable' "$CONSUMER"; then
  pass "mcpProxy.enable declared on hermesPnP"
else
  fail "default.nix must set services.hermesPnP.mcpProxy.enable"
fi
if grep -q 'mcpServers.open-banking-io' "$CONSUMER" \
  || grep -q 'mcpServers.banksync' "$CONSUMER"; then
  fail "banking mcpServers still in default.nix (use modules/ + mcp-proxy)"
else
  pass "banking MCP not declared on default.nix"
fi
if grep -q 'mcpProxy.backends.open-banking-io' "$OPENBANKING" \
  && grep -q 'mcpServers.open-banking-io' "$OPENBANKING" \
  && grep -q 'LoadCredential' "$OPENBANKING"; then
  pass "open-banking.io MCP via mcp-proxy + obi-mcp-http LoadCredential"
else
  fail "missing open-banking.io mcp-proxy / LoadCredential wiring"
fi
if grep -q 'mcpProxy.backends.banksync' "$BANKSYNC" \
  && grep -q 'mcpServers.banksync' "$BANKSYNC" \
  && grep -q 'X-API-Key' "$BANKSYNC"; then
  pass "BankSync MCP via mcp-proxy X-API-Key"
else
  fail "missing banksync mcp-proxy wiring"
fi
if grep -qE 'OBI_API_KEY =|BANKSYNC_API_KEY =' "$SOPS"; then
  fail "banking keys still mapped into hermesEnv"
else
  pass "banking keys kept off hermesEnv"
fi

if grep -q 'proxyServices' "$CONSUMER" \
  && grep -q 'cloudflareTunnel.proxyServices' "$CONSUMER"; then
  pass "WebUI uses host Caddy + cloudflareTunnel proxyServices"
else
  fail "default.nix must use services.caddy.proxyServices + cloudflareTunnel.proxyServices"
fi
if grep -q 'browser.gate.publicUrl' "$CONSUMER" \
  && grep -q 'proxyServices."browser' "$CONSUMER"; then
  pass "browser gate fronted by Caddy :4848"
else
  fail "default.nix must set browser.gate.publicUrl + caddy proxyServices browser.* = 4848"
fi
if grep -q 'cloudflareTunnel.proxyServices."browser' "$CONSUMER"; then
  fail "browser gate must not be on Cloudflare tunnel"
else
  pass "browser gate is LAN/Tailscale only"
fi
if grep -qE 'noVNC|:6080|NOVNC' "$CONSUMER" "$HERMES_AGENTS" "$HERMES/BOOTSTRAP.md"; then
  fail "stale noVNC / :6080 leftover after agent-browser gate"
else
  pass "no leftover noVNC / :6080"
fi
if grep -q 'extraGroups = \[ "docker" \]' "$RUNTIME"; then
  fail "hermes still in docker group (socket is root-equivalent)"
else
  pass "hermes not in docker group"
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

if [[ -f "$HERMES/BOOTSTRAP.md" ]]; then
  pass "BOOTSTRAP present"
else
  fail "missing BOOTSTRAP.md"
fi
if [[ -d "$HERMES/memory" ]]; then
  fail "hermes/memory leftover (registry was unused; pruned)"
else
  pass "no hermes/memory registry"
fi
if [[ -e "$HERMES/TOOLS.md" ]]; then
  fail "TOOLS.md leftover (toolbox is composer-owned)"
else
  pass "no leftover TOOLS.md"
fi
if [[ -d "$HERMES/reference" ]]; then
  fail "hermes/reference leftover (operator docs folded / moved to hermes-pnp)"
else
  pass "no leftover hermes/reference"
fi
if [[ -e "$HERMES/scripts/gbrain-setup.sh" ]] || [[ -e "$HERMES/scripts/validate-gbrain-integration.sh" ]]; then
  fail "gbrain setup/validate still under hermes/scripts (belong in hermes-pnp)"
else
  pass "gbrain operator scripts not vendored on host"
fi
if [[ -d "$HERMES/prompts" ]]; then
  fail "hermes/prompts leftover (bootstrap query lives in hermes-pnp scripts/)"
else
  pass "no leftover hermes/prompts"
fi

if grep -q 'gbrain.enable' "$CONSUMER"; then
  pass "default.nix enables composer gbrain hook"
else
  fail "default.nix must set services.hermesPnP.gbrain.enable"
fi

if grep -q 'activationScripts.hermes-gbrain-site' "$CONSUMER" "$RUNTIME" "$COMPOSIO"; then
  fail "consumer still rewrites config.yaml Bearer (composer owns that)"
else
  pass "no consumer GBrain yaml rewrite"
fi

for opt in enable extraDependencyGroups addToSystemPackages; do
  if grep -q "$opt" "$CONSUMER"; then
    :
  else
    fail "declaration missing expected option surface: $opt"
  fi
done
pass "core hermes-agent option surfaces present in default.nix"

if grep -q 'package.override' "$CONSUMER"; then
  fail "webui must not override the agent package"
else
  pass "webui does not override agent package"
fi
if grep -q 'API_SERVER_' "$CONSUMER"; then
  fail "consumer still redeclares API_SERVER_* (belongs in sops hermes.env only)"
else
  pass "consumer does not redeclare API_SERVER_*"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "ALIGNMENT CHECK FAILED"
  exit 1
fi
echo
echo "ALIGNMENT CHECK OK"
exit 0
