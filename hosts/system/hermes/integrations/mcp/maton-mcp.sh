#!/bin/bash
# Stdio MCP entry for Maton. Hermes filters ambient secrets from MCP children;
# source hermes .env here so MATON_API_KEY reaches @maton/mcp.
# Use absolute bash shebang (not /usr/bin/env) — MCP stdio may start with a PATH
# that makes `env` fail to resolve bash and surface as ENOENT on this script.
set -euo pipefail
export PATH="/data/toolbox/bin:/home/hermes/.npm-global/bin:/var/lib/hermes/toolbox/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"
for candidate in "${HERMES_HOME:-}/.env" /data/.hermes/.env /var/lib/hermes/.hermes/.env; do
  if [ -n "${candidate}" ] && [ -f "$candidate" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$candidate"
    set +a
    break
  fi
done
if [ -z "${MATON_API_KEY:-}" ]; then
  echo "maton-mcp: MATON_API_KEY not found in hermes .env" >&2
  exit 1
fi
# Prefer absolute npx when toolbox is present (filtered MCP env is otherwise sparse).
if [ -x /data/toolbox/bin/npx ]; then
  exec /data/toolbox/bin/npx -y @maton/mcp "$@"
fi
if [ -x /var/lib/hermes/toolbox/bin/npx ]; then
  exec /var/lib/hermes/toolbox/bin/npx -y @maton/mcp "$@"
fi
exec npx -y @maton/mcp "$@"
