#!/usr/bin/env bash
# Read-only Robinhood Crypto MCP launcher for Hermes.
# Runs the data server only (npx robinhood-mcp). Never the trading binary.
# Trading opt-in is explicitly stripped so ROBINHOOD_CRYPTO_ENABLE_TRADING cannot leak in.
set -euo pipefail

# Prefer dedicated env file (sops template → /run/hermes-robinhood.env).
# Also accept paths under hermes state (container /data, host /var/lib/hermes).
for f in \
  /run/hermes-robinhood.env \
  /data/.hermes/robinhood.env \
  /var/lib/hermes/.hermes/robinhood.env
do
  if [[ -f "$f" && -r "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  fi
done

# Hard read-only: never pass trading enable into the data server.
unset ROBINHOOD_CRYPTO_ENABLE_TRADING 2>/dev/null || true
export ROBINHOOD_CRYPTO_ENABLE_TRADING=0

if [[ -z "${ROBINHOOD_CRYPTO_API_KEY:-}" || -z "${ROBINHOOD_CRYPTO_PRIVATE_KEY:-}" ]]; then
  echo "robinhood-mcp-readonly: missing ROBINHOOD_CRYPTO_API_KEY and/or ROBINHOOD_CRYPTO_PRIVATE_KEY" >&2
  echo "  1) npx robinhood-keygen  (Ed25519 seed + public key)" >&2
  echo "  2) Register public key at https://robinhood.com/account/crypto (classic web UI)" >&2
  echo "  3) Add keys via sops (see hosts/system/hermes/BOOTSTRAP.md § Robinhood Crypto MCP)" >&2
  echo "  4) systemctl restart hermes-agent" >&2
  # Data server still starts and exposes get_setup_status when creds are absent.
fi

# Data server only — never robinhood-mcp-trading / robinhood-mcp-daemon.
exec npx -y robinhood-mcp "$@"
