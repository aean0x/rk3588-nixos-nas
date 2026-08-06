# Cloudflare Tunnel — public HTTPS behind CGNAT (Starlink, etc.).
#
# Mirror of Caddy's proxyServices, for the WAN path:
#
#   services.caddy.proxyServices."app.${domain}" = 8080;           # LAN
#   services.cloudflareTunnel.proxyServices."app.${domain}" = 8080; # public
#
# Why not orange-cloud + DDNS? Under CGNAT nothing can dial your origin IPv4.
# Tunnel is outbound-only: browser → Cloudflare edge → cloudflared → 127.0.0.1:port
#
# Bootstrap (once): ./scripts/setup-cloudflare-tunnel.sh
#   - needs Account.Cloudflare Tunnel:Edit on cloudflare_dns_api_token
#   - writes sops credentials + settings.cloudflareTunnelId
#   - creates proxied CNAMEs for every hostname in proxyServices
#
# Empty settings.cloudflareTunnelId → tunnel disabled (LAN-only via Caddy).
{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.services.cloudflareTunnel;
  tunnelId = settings.cloudflareTunnelId or "";
  enabled = tunnelId != "";

  # int 8080 → http://127.0.0.1:8080 ; string used as-is (http://…, unix:…, …)
  toService =
    v: if builtins.isInt v then "http://127.0.0.1:${toString v}" else v;

  ingress = lib.mapAttrs (_host: toService) cfg.proxyServices;
in
{
  options.services.cloudflareTunnel = {
    proxyServices = lib.mkOption {
      description = ''
        Map of public hostnames to backends for Cloudflare Tunnel ingress.
        Same shape as services.caddy.proxyServices: port int or full service URL.
        Modules declare here for WAN; Caddy separately for LAN.
      '';
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.int
          lib.types.str
        ]
      );
      default = { };
      example = {
        "archimedes.example.io" = 8787;
        "homeassistant.example.io" = 8123;
      };
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = cfg.proxyServices != { };
        message = ''
          settings.cloudflareTunnelId is set but services.cloudflareTunnel.proxyServices is empty.
          Declare hostnames in service modules, e.g.:
            services.cloudflareTunnel.proxyServices."app.${settings.domain}" = 8080;
        '';
      }
    ];

    # DynamicUser + LoadCredential; root-owned secret is fine.
    sops.secrets.cloudflared_tunnel_credentials = { };

    services.cloudflared = {
      enable = true;
      tunnels.${tunnelId} = {
        credentialsFile = config.sops.secrets.cloudflared_tunnel_credentials.path;
        edgeIPVersion = "auto";
        protocol = "auto";
        default = "http_status:404";
        inherit ingress;
      };
    };
  };
}
