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
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
    hash = "sha256-VHm9POg2KixGsMsAcfFFDMK9x6niRJ1iJV9kkSwkSjc=";
  };

  # Build handle blocks for each proxy service
  mkHandle =
    host: port:
    let
      isExt = builtins.elem host cfg.externalHosts;
      guard = lib.optionalString (!isExt) ''
        @denied_${builtins.replaceStrings [ "." ] [ "_" ] host} not remote_ip 192.168.2.0/24 127.0.0.1
        respond @denied_${builtins.replaceStrings [ "." ] [ "_" ] host} 403
      '';
    in
    ''
      @${builtins.replaceStrings [ "." ] [ "_" ] host} host ${host}
      handle @${builtins.replaceStrings [ "." ] [ "_" ] host} {
        ${guard}
        reverse_proxy 127.0.0.1:${toString port} {
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      }
    '';

  allHandles = lib.concatStringsSep "\n" (lib.mapAttrsToList mkHandle cfg.proxyServices);

in
{
  options.services.caddy = {
    proxyServices = lib.mkOption {
      description = "Map of hostnames to backend ports for reverse proxying.";
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.int
          lib.types.str
        ]
      );
      default = { };
    };

    externalHosts = lib.mkOption {
      description = "Hostnames accessible from WAN. All others return 403 to non-LAN clients.";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = {
    services.caddy = {
      enable = true;
      package = caddyWithCloudflare;

      # Single wildcard site — one cert issuance, avoids per-host zone detection bugs
      extraConfig = ''
        *.${domain}, ${domain} {
          tls {
            dns cloudflare {env.CF_DNS_API_TOKEN}
            resolvers 1.1.1.1 8.8.8.8
          }

          ${allHandles}

          handle {
            respond 404
          }
        }
      '';

      # Root domain + HA subdomain are externally accessible
      proxyServices."${domain}" = 8123;
      externalHosts = [
        "${domain}"
        "homeassistant.${domain}"
      ];
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
