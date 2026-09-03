# Tailscale VPN (native NixOS)
#
# Public DNS for *.aean.io is the Cloudflare tunnel CNAME, so a phone on the
# tailnet using public resolvers never reaches Caddy. Publish a wildcard
# grey-cloud A record `*.aean.io` at the node's Tailscale IPv4 instead —
# unroutable off-net, Caddy already allows 100.64.0.0/10. Exact records
# (tunnel CNAMEs like archimedes./homeassistant.) keep DNS priority, so the
# wildcard only catches undeclared hosts → tailnet-only reachability.
{
  config,
  pkgs,
  settings,
  ...
}:
let
  wildcardHost = "*.${settings.domain}";
  browserHost = "browser.${settings.domain}";
in
{
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_authKey.path;
    openFirewall = true;
    extraUpFlags = [
      "--ssh"
      "--accept-routes"
      "--accept-dns"
      "--advertise-routes=192.168.1.0/24"
    ];
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    80
    443
  ];

  systemd.services.tailscale-wildcard-dns = {
    description = "Cloudflare grey-cloud A record ${wildcardHost} → Tailscale IPv4";
    after = [
      "tailscaled.service"
      "network-online.target"
    ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [
      pkgs.curl
      pkgs.jq
      pkgs.tailscale
    ];
    script = ''
      set -euo pipefail
      TOKEN=$(cat ${config.sops.secrets.cloudflare_dns_api_token.path})
      for _ in $(seq 1 30); do
        IP=$(tailscale ip -4 2>/dev/null || true)
        if [ -n "$IP" ]; then
          break
        fi
        sleep 2
      done
      if [ -z "''${IP:-}" ]; then
        echo "tailscale IPv4 not ready" >&2
        exit 1
      fi
      ZONE_JSON=$(curl -sS -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=${settings.domain}")
      ZONE_ID=$(echo "$ZONE_JSON" | jq -r '.result[0].id // empty')
      if [ -z "$ZONE_ID" ]; then
        echo "cloudflare zone not found for ${settings.domain}" >&2
        exit 1
      fi
      RECORDS=$(curl -sS -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=500")

      # Drop a stale grey A at browser.<domain> (an earlier deploy of the
      # exact-record variant) so the wildcard actually governs that host.
      STALE=$(echo "$RECORDS" | jq -r --arg n "${browserHost}" \
        '.result[] | select(.name==$n and .type=="A" and (.content|startswith("100."))) | .id')
      for id in $STALE; do
        curl -sS -X DELETE -H "Authorization: Bearer $TOKEN" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
          | jq -e '.success == true' >/dev/null
      done

      # Wildcard: replace any non-A record (e.g. tunnel CNAME) at *.aean.io.
      WC_OTHER=$(echo "$RECORDS" | jq -r --arg n "${wildcardHost}" \
        '.result[] | select(.name==$n and .type!="A") | .id')
      for id in $WC_OTHER; do
        curl -sS -X DELETE -H "Authorization: Bearer $TOKEN" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
          | jq -e '.success == true' >/dev/null
      done

      WC_A=$(echo "$RECORDS" | jq -r --arg n "${wildcardHost}" \
        '.result[] | select(.name==$n and .type=="A") | .id' | head -1)
      BODY=$(jq -n --arg name "${wildcardHost}" --arg ip "$IP" \
        '{type:"A", name:$name, content:$ip, ttl:120, proxied:false}')
      if [ -n "$WC_A" ]; then
        curl -sS -X PUT -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          --data "$BODY" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$WC_A" \
          | jq -e '.success == true' >/dev/null
      else
        curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          --data "$BODY" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
          | jq -e '.success == true' >/dev/null
      fi
      echo "${wildcardHost} -> $IP (grey cloud)"
    '';
  };

  systemd.timers.tailscale-wildcard-dns = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
    };
  };
}
