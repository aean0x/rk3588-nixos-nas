#!/usr/bin/env bash
# Bootstrap Cloudflare Tunnel + DNS for services.cloudflareTunnel.proxyServices.
#
# Once:
#   1. API token has Zone.DNS:Edit + Account.Cloudflare Tunnel:Edit
#   2. ./scripts/setup-cloudflare-tunnel.sh
#   3. git add settings.nix secrets/secrets.yaml && ./deploy remote-test
#
# After adding a new public hostname in Nix:
#   ./scripts/setup-cloudflare-tunnel.sh          # re-syncs DNS from flake
#   ./deploy remote-test
#
# Optional: pass hostnames explicitly instead of reading the flake:
#   ./scripts/setup-cloudflare-tunnel.sh app.example.io other.example.io
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets"
SETTINGS="${REPO_ROOT}/settings.nix"
DOMAIN="$(sed -n 's/^[[:space:]]*domain = "\([^"]*\)";.*/\1/p' "$SETTINGS" | head -1)"
DOMAIN="${DOMAIN:-aean.io}"
HOST_NAME="$(sed -n 's/^[[:space:]]*hostName = "\([^"]*\)";.*/\1/p' "$SETTINGS" | head -1)"
HOST_NAME="${HOST_NAME:-rocknas}"
TUNNEL_NAME="${TUNNEL_NAME:-rocknas}"

if [[ ! -f "${SECRETS_DIR}/key.txt" ]]; then
  echo "error: ${SECRETS_DIR}/key.txt missing" >&2
  exit 1
fi

export SOPS_AGE_KEY_FILE="${SECRETS_DIR}/key.txt"
export SOPS_CONFIG="${SECRETS_DIR}/.sops.yaml"

PLAIN="$(mktemp)"
CREDS="$(mktemp)"
trap 'rm -f "$PLAIN" "$CREDS"' EXIT
chmod 600 "$PLAIN" "$CREDS"

sops -d "${SECRETS_DIR}/secrets.yaml" >"$PLAIN"
CF_TOKEN="$(awk '/^cloudflare_dns_api_token:/{print $2; exit}' "$PLAIN" | tr -d '"')"
if [[ -z "$CF_TOKEN" || ${#CF_TOKEN} -lt 20 ]]; then
  echo "error: cloudflare_dns_api_token missing from secrets" >&2
  exit 1
fi

api() {
  local method="$1" url="$2"
  shift 2
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

json_success() { echo "$1" | grep -q '"success":[[:space:]]*true'; }

# Hostnames: CLI args, else flake proxyServices attrNames
HOSTNAMES=()
if [[ $# -gt 0 ]]; then
  HOSTNAMES=("$@")
else
  echo "==> Read hostnames from flake (services.cloudflareTunnel.proxyServices)"
  # git-add required so flake sees current modules
  mapfile -t HOSTNAMES < <(
    nix eval --raw ".#nixosConfigurations.${HOST_NAME}.config.services.cloudflareTunnel.proxyServices" \
      --apply 'ps: builtins.concatStringsSep "\n" (builtins.attrNames ps)' 2>/dev/null || true
  )
  if [[ ${#HOSTNAMES[@]} -eq 0 || -z "${HOSTNAMES[0]:-}" ]]; then
    echo "    (none yet — declare proxyServices in modules, git add, re-run)"
  else
    printf '    %s\n' "${HOSTNAMES[@]}"
  fi
fi

echo "==> Resolve account + zone for ${DOMAIN}"
ZONE_JSON="$(api GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}")"
ZONE_ID="$(
  echo "$ZONE_JSON" | tr ',' '\n' | awk -v d="\"${DOMAIN}\"" '
    /"id":"[a-f0-9]{32}"/ {
      id=$0; sub(/.*"id":"/,"",id); sub(/".*/,"",id); last=id
    }
    $0 ~ "\"name\":" d {
      if (last != "") { print last; exit }
    }
  '
)"
[[ -z "$ZONE_ID" ]] && ZONE_ID="$(echo "$ZONE_JSON" | tr ',' '\n' | sed -n 's/.*"id":"\([a-f0-9]\{32\}\)".*/\1/p' | head -1)"
ACCOUNT_ID="$(echo "$ZONE_JSON" | sed -n 's/.*"account":{"id":"\([a-f0-9]\{32\}\)".*/\1/p' | head -1)"
if [[ -z "$ZONE_ID" || -z "$ACCOUNT_ID" ]]; then
  echo "error: could not resolve zone/account for ${DOMAIN}" >&2
  echo "$ZONE_JSON" | head -c 400 >&2
  exit 1
fi
echo "    zone=${ZONE_ID} account=${ACCOUNT_ID}"

echo "==> Tunnel ${TUNNEL_NAME}"
LIST="$(api GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?is_deleted=false&name=${TUNNEL_NAME}")"
if ! json_success "$LIST"; then
  echo "error: cannot list tunnels — token needs Account.Cloudflare Tunnel:Edit" >&2
  echo "$LIST" | head -c 400 >&2
  exit 1
fi

TUNNEL_ID="$(echo "$LIST" | tr ',' '\n' | sed -n 's/.*"id":"\([0-9a-f-]\{36\}\)".*/\1/p' | head -1)"
NEED_NEW_CREDS=0

if [[ -n "$TUNNEL_ID" ]]; then
  echo "    existing ${TUNNEL_ID}"
  EXISTING_JSON="$(
    awk '
      /^cloudflared_tunnel_credentials:/ {
        rest=$0; sub(/^cloudflared_tunnel_credentials:[[:space:]]*/,"",rest)
        if (rest != "" && rest != "|" && rest != ">-") { print rest; exit }
        while (getline > 0) {
          if ($0 ~ /^[a-zA-Z0-9_]+:/) exit
          line=$0; sub(/^[[:space:]]+/,"",line); printf "%s", line
        }
        exit
      }
    ' "$PLAIN" | tr -d "'"
  )"
  if echo "$EXISTING_JSON" | grep -q "$TUNNEL_ID" && ! echo "$EXISTING_JSON" | grep -q '\.\.\.'; then
    printf '%s\n' "$EXISTING_JSON" >"$CREDS"
  else
    echo "error: tunnel exists but sops credentials missing/placeholder" >&2
    echo "       delete tunnel '${TUNNEL_NAME}' in Zero Trust UI or restore credentials JSON" >&2
    exit 1
  fi
else
  echo "    creating..."
  TUNNEL_SECRET="$(openssl rand -base64 32)"
  CREATE="$(api POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel" \
    --data "$(printf '{"name":"%s","tunnel_secret":"%s","config_src":"local"}' "$TUNNEL_NAME" "$TUNNEL_SECRET")")"
  if ! json_success "$CREATE"; then
    echo "error: tunnel create failed — add Account · Cloudflare Tunnel · Edit to API token" >&2
    echo "$CREATE" | head -c 600 >&2
    exit 1
  fi
  TUNNEL_ID="$(echo "$CREATE" | tr ',' '\n' | sed -n 's/.*"id":"\([0-9a-f-]\{36\}\)".*/\1/p' | head -1)"
  printf '{"AccountTag":"%s","TunnelID":"%s","TunnelSecret":"%s"}\n' \
    "$ACCOUNT_ID" "$TUNNEL_ID" "$TUNNEL_SECRET" >"$CREDS"
  NEED_NEW_CREDS=1
  echo "    created ${TUNNEL_ID}"
fi

if [[ "$NEED_NEW_CREDS" -eq 1 ]]; then
  echo "==> Write sops cloudflared_tunnel_credentials"
  CREDS_LINE="$(tr -d '\n' <"$CREDS")"
  CREDS_JSON_STR="$(printf '%s' "$CREDS_LINE" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  (cd "${SECRETS_DIR}" && sops set secrets.yaml '["cloudflared_tunnel_credentials"]' "\"${CREDS_JSON_STR}\"")
fi

echo "==> settings.cloudflareTunnelId = ${TUNNEL_ID}"
if grep -q 'cloudflareTunnelId' "$SETTINGS"; then
  sed -i "s/cloudflareTunnelId = \".*\";/cloudflareTunnelId = \"${TUNNEL_ID}\";/" "$SETTINGS"
else
  echo "error: settings.nix missing cloudflareTunnelId" >&2
  exit 1
fi

if [[ ${#HOSTNAMES[@]} -gt 0 && -n "${HOSTNAMES[0]:-}" ]]; then
  echo "==> DNS CNAME → ${TUNNEL_ID}.cfargotunnel.com (proxied)"
  CONTENT="${TUNNEL_ID}.cfargotunnel.com"
  for host in "${HOSTNAMES[@]}"; do
    [[ -z "$host" ]] && continue
    echo "    ${host}"
    while true; do
      EXIST="$(api GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${host}")"
      RID="$(echo "$EXIST" | tr ',' '\n' | sed -n 's/.*"id":"\([a-f0-9]\{32\}\)".*/\1/p' | head -1)"
      [[ -z "$RID" ]] && break
      api DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RID}" >/dev/null || true
    done
    BODY="$(printf '{"type":"CNAME","name":"%s","content":"%s","proxied":true,"ttl":1}' "$host" "$CONTENT")"
    RESP="$(api POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" --data "$BODY")"
    if json_success "$RESP"; then
      echo "      ok"
    else
      echo "      FAILED: $RESP" >&2
      exit 1
    fi
  done
fi

echo
echo "Done. TunnelID=${TUNNEL_ID}"
echo "Next: git add settings.nix secrets/secrets.yaml && ./deploy remote-test"
echo "Check: curl -sSI https://archimedes.${DOMAIN}/ | head -15"
