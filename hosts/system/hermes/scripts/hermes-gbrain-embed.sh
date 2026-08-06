#!/usr/bin/env bash
# Host-only GBrain embed --stale (exclusive via hermes-gbrain-exclusive).
set -euo pipefail

LOG_TAG="hermes-gbrain-embed"
STATE="${HERMES_STATE_DIR:-/var/lib/hermes/.hermes}"
HOME_DIR="${HERMES_USER_HOME:-/var/lib/hermes/home}"
export HOME="$HOME_DIR"
export PATH="${HOME_DIR}/.bun/bin:${HOME_DIR}/.npm-global/bin:/var/lib/hermes/toolbox/bin:/run/current-system/sw/bin:/usr/bin:/bin"
# Container absolute paths in gbrain config need this host symlink.
if [[ ! -e /home/hermes ]]; then
  ln -sfn "$HOME_DIR" /home/hermes 2>/dev/null || true
fi

log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",$1}"; }

for f in /run/hermes.env "$STATE/.env"; do
  [[ -f "$f" ]] || continue
  set -a
  # shellcheck disable=SC1090
  source <(grep -E '^(ZEROENTROPY_API_KEY|OPENAI_API_KEY)=' "$f" || true)
  set +a
done

if [[ -z "${ZEROENTROPY_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
  log '"embed":"skip","reason":"no_embedding_api_key"'
  exit 0
fi

# Re-exec under exclusive runner unless already held.
if [[ "${HERMES_GBRAIN_EXCLUSIVE:-}" != 1 ]]; then
  EXCL="${HERMES_GBRAIN_EXCLUSIVE_BIN:-hermes-gbrain-exclusive}"
  if ! command -v "$EXCL" >/dev/null 2>&1; then
    log '"error":"exclusive_runner_missing"'
    exit 2
  fi
  log '"event":"delegating_to_exclusive_runner"'
  exec "$EXCL" -- env HERMES_GBRAIN_EXCLUSIVE=1 \
    ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY:-}" \
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    "$0" "$@"
fi

# Payload runs as hermes (exclusive default) with cwd under HOME.
set +e
gbrain embed --stale 2> >(tee /tmp/gbrain-embed.err >&2)
ec=$?
set -e
if [[ "$ec" -ne 0 ]] && grep -qiE 'WASM|Aborted|already (instantiated|open)|multiple PGLite|failed to initialize' /tmp/gbrain-embed.err 2>/dev/null; then
  log '"error":"pglite_wasm_or_lock","hint":"exclusive gbrain doctor; backup brain.pglite; reinit only if doctor confirms — never auto-reinit (see workspace/GBRAIN.md)"'
fi
echo "{\"embed\":$([[ $ec -eq 0 ]] && echo true || echo false)}"
log '"status":"complete"'
exit "$ec"
