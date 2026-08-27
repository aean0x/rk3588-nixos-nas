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
    hash = "sha256-dQvk6ezY6TQ1J7PjhCXnThF/SqVgPwBO8/RXzHCY+js=";
  };

  # Build handle blocks for each proxy service
  mkHandle =
    host: port:
    let
      isExt = builtins.elem host cfg.externalHosts;
      # Loopback backends that validate Host against the listen address need
      # a rewrite or clients get 400 Invalid Host.
      upstreamHost = cfg.proxyUpstreamHost.${host} or null;
      hostRewrite = lib.optionalString (upstreamHost != null) ''
        header_up Host ${upstreamHost}
      '';
      guard = lib.optionalString (!isExt) ''
        @denied_${builtins.replaceStrings [ "." ] [ "_" ] host} not remote_ip ${
          if (settings.enableRouter or false) then "192.168.2.0/24" else "192.168.1.0/24"
        } 127.0.0.1 100.64.0.0/10
        respond @denied_${builtins.replaceStrings [ "." ] [ "_" ] host} 403
      '';
    in
    ''
      @${builtins.replaceStrings [ "." ] [ "_" ] host} host ${host}
      handle @${builtins.replaceStrings [ "." ] [ "_" ] host} {
        ${guard}
        reverse_proxy 127.0.0.1:${toString port} {
          ${hostRewrite}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-Host {host}
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

    proxyUpstreamHost = lib.mkOption {
      description = ''
        Optional Host header rewrite per proxyServices hostname.
        Use for loopback backends that reject non-loopback Host (DNS-rebinding
        protection on 127.0.0.1 binds).
      '';
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "hermes.example.io" = "127.0.0.1:9119";
      };
    };
  };

  config = {
    services.caddy = {
      enable = true;
      package = caddyWithCloudflare;

      # Declarative Caddyfile only. Default admin (127.0.0.1:2019) is
      # unauthenticated; host-net jails share that loopback. Reload uses
      # the admin API, so turn it off and restart on config change.
      enableReload = false;
      globalConfig = ''
        admin off
      '';

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

      # Root domain + HA subdomain are externally accessible.
      # Use mkDefault so other modules can add to the lists without "defined multiple times".
      proxyServices."${domain}" = lib.mkDefault 8123;
      externalHosts = lib.mkDefault [
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
