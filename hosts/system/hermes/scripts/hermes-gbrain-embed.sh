#!/usr/bin/env bash
# Host-only GBrain embed --stale (stops hermes-agent for exclusive PGLite).
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

log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",\"msg\":$1}"; }

started=0
cleanup() {
  if [[ "$started" -eq 1 ]]; then
    systemctl start hermes-agent.service 2>/dev/null || true
  fi
}
trap cleanup EXIT

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

log '"event":"stopping_hermes_for_pglite"'
systemctl stop hermes-agent.service
started=1
sleep 2
rm -rf "$HOME_DIR/.gbrain/brain.pglite/.gbrain-lock" 2>/dev/null || true

# cwd under hermes HOME so bun can posix_spawn (see consolidate.sh)
set +e
runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" \
  ZEROENTROPY_API_KEY="${ZEROENTROPY_API_KEY:-}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
  bash -c 'cd "$HOME" && exec gbrain embed --stale'
ec=$?
set -e
echo "{\"embed\":$([[ $ec -eq 0 ]] && echo true || echo false)}"
log '"status":"complete"'
exit "$ec"
