{
  config,
  lib,
  pkgs,
  settings,
  ...
}:

let
  cfg = config.services.caddy;
  domain = settings.domain;

  caddyWithCloudflare = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.1" ];
    hash = "sha256-hZKTEzevrabjgZCCcoRKlqUfdDIUr89KEFJ84kyFxeg=";
  };

  # Generates a pair of vhosts (HTTP redirect + HTTPS proxy) for a given domain/port
  mkProxy = host: port: {
    "http://${host}" = {
      extraConfig = "redir https://${host}{uri}";
    };
    "https://${host}" = {
      extraConfig = ''
        tls {
          dns cloudflare {env.CF_DNS_API_TOKEN}
        }
        reverse_proxy 127.0.0.1:${toString port} {
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };
  };

  # Flatten the proxyServices map into a single attribute set of Caddy virtualHosts
  generatedVHosts = lib.foldl' (acc: host: acc // (mkProxy host cfg.proxyServices.${host})) { } (
    builtins.attrNames cfg.proxyServices
  );

in
{
  options.services.caddy = {
    proxyServices = lib.mkOption {
      description = "Map of hostnames to backend ports. Configures ACME DNS-01 TLS via Cloudflare and HTTP redirects.";
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.int
          lib.types.str
        ]
      );
      default = { };
    };
  };

  config = {
    services.caddy = {
      enable = true;
      package = caddyWithCloudflare;

      # Root domain goes to Home Assistant
      proxyServices."${domain}" = 8123;

      virtualHosts = generatedVHosts;
    };

    # Inject Cloudflare API token from SOPS into Caddy's environment
    systemd.services.caddy.serviceConfig.EnvironmentFile = "/run/caddy.env";
    systemd.services.caddy-env = {
      description = "Caddy secrets injector";
      before = [ "caddy.service" ];
      requiredBy = [ "caddy.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo "CF_DNS_API_TOKEN=$(cat ${config.sops.secrets.cloudflare_dns_api_token.path})" > /run/caddy.env
        chmod 0600 /run/caddy.env
      '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
