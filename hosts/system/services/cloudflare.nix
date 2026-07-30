# Cloudflare DDNS — apex A/AAAA only (grey cloud).
# Public apps use services.cloudflareTunnel.proxyServices (see cloudflared.nix), not this.
{ config, settings, ... }:
{
  services.cloudflare-dyndns = {
    enable = true;
    apiTokenFile = config.sops.secrets.cloudflare_dns_api_token.path;
    domains = [ settings.domain ];
    ipv6 = true;
    proxied = false; # CGNAT: orange-cloud origin pull fails without a tunnel
  };
}
