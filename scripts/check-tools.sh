#!/usr/bin/env bash
# Structural + optional remote check for hermes everyday tools.
# Toolbox lives in hermes-pnp; this host only asserts it is wired.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hosts/system/hermes"
CONSUMER="$H/hermes.nix"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

if [[ -f "$H/toolbox.nix" ]]; then
  fail "toolbox.nix leftover on host (composer owns it)"
else
  pass "no host toolbox.nix"
fi
if grep -q 'inputs.hermes-pnp.nixosModules.default' "$CONSUMER" \
  && grep -q 'services.hermesPnP' "$CONSUMER"; then
  pass "hermes.nix imports composer (toolbox)"
else
  fail "composer not imported from hermes.nix"
fi
if grep -q 'toolbox.extraPackages' "$CONSUMER"; then
  pass "consumer extends composer toolbox"
else
  fail "hermes.nix should extend hermesPnP.toolbox (extraPackages)"
fi
if grep -q 'mcpServers.gbrain' "$CONSUMER" "$H/runtime.nix"; then
  fail "consumer still declares mcpServers.gbrain (composer owns HTTP url)"
else
  pass "MCP gbrain URL left to composer"
fi
if grep -q 'gbrain.enable' "$CONSUMER"; then
  pass "composer gbrain hook enabled"
else
  fail "hermes.nix must set services.hermesPnP.gbrain.enable"
fi

if [[ "${REMOTE_CHECK:-}" == 1 ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/scripts/common.sh"
  check_ssh
  echo "=== remote tool probe (login shell) ==="
  remote_out=$(ssh ${SSH_OPTS} "$TARGET" 'sudo docker exec -u hermes hermes-agent bash -lc "
    set -e
    echo PATH=\$PATH
    test -d /data/toolbox/bin && echo TOOLBOX_DIR=yes || echo TOOLBOX_DIR=no
    missing=0
    for c in git rg jq bun node gbrain python python3 ffmpeg curl wget unzip yq file which rsync ssh pandoc nmap strace; do
      p=\$(command -v \$c 2>/dev/null || true)
      if [ -n \"\$p\" ]; then echo OK \$c=\$p; else echo MISSING \$c; missing=1; fi
    done
    echo BROWSER_CDP_URL=\${BROWSER_CDP_URL:-unset}
    for c in git rg jq bun gbrain python python3 curl; do
      command -v \$c >/dev/null || exit 2
    done
    exit 0
  "' 2>&1) || {
    echo "$remote_out"
    fail "remote tool probe failed"
    remote_out=""
  }
  echo "$remote_out"
  echo "$remote_out" | grep -q 'TOOLBOX_DIR=yes' && pass "remote /data/toolbox/bin present" || fail "remote toolbox dir missing"
  echo "$remote_out" | grep -q 'MISSING' && fail "remote has missing tools" || pass "remote critical tools present"
  echo "$remote_out" | grep -q '/data/toolbox/bin' && pass "PATH includes toolbox" || fail "PATH missing toolbox"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo; echo "TOOL CHECK FAILED"; exit 1
fi
echo; echo "TOOL CHECK OK"
exit 0
