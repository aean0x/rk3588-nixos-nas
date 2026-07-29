#!/usr/bin/env bash
# Structural + optional remote check for hermes everyday tools.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
H="$ROOT/hosts/system/hermes"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

[[ -f "$H/toolbox.nix" ]] && pass "toolbox.nix exists" || fail "missing toolbox.nix"
grep -q './toolbox.nix' "$H/default.nix" && pass "default.nix imports toolbox" || fail "toolbox not imported"
grep -q 'hermes-toolbox\|buildEnv' "$H/toolbox.nix" && pass "buildEnv toolbox defined" || fail "no buildEnv"
grep -q '/data/toolbox/bin' "$H/toolbox.nix" && pass "container toolbox path in PATH" || fail "no /data/toolbox/bin"
grep -q 'ln -sfn.*toolbox' "$H/toolbox.nix" && pass "activation links toolbox bin" || fail "no toolbox symlink activation"
for pkg in git ripgrep jq bun nodejs ffmpeg curl unzip openssh; do
  grep -q "$pkg" "$H/toolbox.nix" && pass "toolbox includes $pkg" || fail "toolbox missing $pkg"
done
# PATH should not be only in gbrain after split
if grep -q 'PATH = "/home/hermes/.npm-global' "$H/gbrain.nix" 2>/dev/null; then
  fail "gbrain.nix still owns full PATH (should be toolbox.nix)"
else
  pass "PATH owned by toolbox.nix not gbrain.nix"
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
    for c in git rg jq bun node gbrain python3 ffmpeg curl wget unzip yq file which rsync ssh pandoc; do
      p=\$(command -v \$c 2>/dev/null || true)
      if [ -n \"\$p\" ]; then echo OK \$c=\$p; else echo MISSING \$c; missing=1; fi
    done
    # critical set must all be present
    for c in git rg jq bun gbrain python3 curl; do
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

  echo "=== gateway child PATH sample (via hermes -Q) ==="
  chat_out=$(ssh ${SSH_OPTS} "$TARGET" 'sudo -u hermes /run/current-system/sw/bin/hermes chat -Q --yolo --accept-hooks -q "
Use the terminal tool once. Run exactly:
echo PATH=\$PATH; command -v git; command -v rg; command -v jq; command -v gbrain; command -v python3; ls /data/toolbox/bin | wc -l
Reply with only the command output.
"' 2>&1) || true
  echo "$chat_out" | tail -40
  echo "$chat_out" | grep -qE 'git|/data/toolbox' && pass "agent session sees tools" || fail "agent session tool probe weak/fail"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo; echo "TOOL CHECK FAILED"; exit 1
fi
echo; echo "TOOL CHECK OK"
exit 0
