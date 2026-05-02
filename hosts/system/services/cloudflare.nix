# Cloudflare services: DDNS
# Updates A + AAAA records with the current public IP every 5 minutes.
{ config, settings, ... }:
{
  services.cloudflare-dyndns = {
    enable = true;
    apiTokenFile = config.sops.secrets.cloudflare_dns_api_token.path;
    domains = [ settings.domain ];
    ipv6 = true;
    proxied = false;
  };
}
