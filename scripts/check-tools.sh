#!/usr/bin/env bash
# Structural + optional remote check for hermes everyday tools.
# Toolbox lives in hermes-pnp; this host only asserts it is wired.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hosts/system/hermes"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

if [[ -f "$H/toolbox.nix" ]]; then
  fail "toolbox.nix leftover on host (composer owns it)"
else
  pass "no host toolbox.nix"
fi
grep -q 'inputs.hermes-pnp.nixosModules.default' "$H/default.nix" \
  && pass "default.nix imports composer (toolbox)" || fail "composer not imported"
grep -q 'toolbox.hostPath' "$H/gbrain.nix" "$H/hermes-webui.nix" \
  && pass "host modules consume composer toolbox.hostPath" || fail "host still hardcodes toolbox PATH"
grep -q 'mcpServers.gbrain' "$H/gbrain.nix" && grep -q 'gbrainMcpUrl\|3131/mcp' "$H/gbrain.nix" \
  && pass "MCP gbrain is HTTP" || fail "MCP gbrain missing HTTP url"

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
