#!/usr/bin/env bash
# Host-only GBrain dream (exclusive via hermes-gbrain-exclusive).
set -euo pipefail

LOG_TAG="hermes-gbrain-dream"
HOME_DIR="${HERMES_USER_HOME:-/var/lib/hermes/home}"
export HOME="$HOME_DIR"
export PATH="${HOME_DIR}/.bun/bin:${HOME_DIR}/.npm-global/bin:/var/lib/hermes/toolbox/bin:/run/current-system/sw/bin:/usr/bin:/bin"

log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",$1}"; }

if [[ ! -e /home/hermes ]]; then
  ln -sfn "$HOME_DIR" /home/hermes 2>/dev/null || true
fi

if [[ "${HERMES_GBRAIN_EXCLUSIVE:-}" != 1 ]]; then
  EXCL="${HERMES_GBRAIN_EXCLUSIVE_BIN:-hermes-gbrain-exclusive}"
  if ! command -v "$EXCL" >/dev/null 2>&1; then
    log '"error":"exclusive_runner_missing"'
    exit 2
  fi
  log '"event":"delegating_to_exclusive_runner"'
  exec "$EXCL" -- env HERMES_GBRAIN_EXCLUSIVE=1 "$0" "$@"
fi

set +e
gbrain dream 2> >(tee /tmp/gbrain-dream.err >&2)
ec=$?
set -e
if [[ "$ec" -ne 0 ]] && grep -qiE 'WASM|Aborted|already (instantiated|open)|multiple PGLite|failed to initialize' /tmp/gbrain-dream.err 2>/dev/null; then
  log '"error":"pglite_wasm_or_lock","hint":"exclusive gbrain doctor; backup brain.pglite; reinit only if doctor confirms — never auto-reinit (see workspace/GBRAIN.md)"'
fi
echo "{\"dream\":$([[ $ec -eq 0 ]] && echo true || echo false)}"
log '"status":"complete"'
exit "$ec"
