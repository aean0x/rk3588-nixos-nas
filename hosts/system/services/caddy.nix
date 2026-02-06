{ config, pkgs, ... }:
{
  services.caddy = {
    enable = true;
    package = pkgs.caddy.override {
      plugins = [ { name = "github.com/caddy-dns/cloudflare"; } ];
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "your@email.com";
    certs = {
      "example.com" = {
        dnsProvider = "cloudflare";
        credentialsFile = config.sops.secrets.services_caddy_cloudflareToken.path; # CLOUDFLARE_API_TOKEN=value
        extraDomainNames = [ "*.example.com" ]; # Wildcard
      };
    };
  };

  # Example vhost - proxy to jellyfin
  services.caddy.virtualHosts."jellyfin.example.com" = {
    useACMEHost = "example.com";
    extraConfig = ''
      reverse_proxy localhost:8096
    '';
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
