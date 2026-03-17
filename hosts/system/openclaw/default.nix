# OpenClaw (non-root gateway + sandboxes via docker.sock)
# Custom image built at runtime on the device via docker build.
# This avoids dockerTools.pullImage cross-arch sandbox issues.
{
  config,
  pkgs,
  lib,
  settings,
  inputs,
  ...
}:
let
  openclawConfig = import ./config.nix {
    inherit pkgs lib settings;
    openclaw-agents = inputs.openclaw-agents;
  };
  openclawPort = openclawConfig.port;
  customImage = "openclaw-custom:latest";
  configDir = "/var/lib/openclaw";

  dockerGid =
    if (config.users.groups ? docker && config.users.groups.docker.gid != null) then
      config.users.groups.docker.gid
    else
      131;
in
{
  imports = [
    ./onedrive.nix
    ./image.nix
    ./deployment.nix
  ];

  options.services.openclaw = {
    envSecrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Map of environment variable names to secret file paths. Populates /run/openclaw.env at deploy time.";
      example = lib.literalExpression ''
        {
          OPENCLAW_GATEWAY_TOKEN = config.sops.secrets.openclaw_gateway_token.path;
          XAI_API_KEY = config.sops.secrets.xai_api_key.path;
        }
      '';
    };
  };

  config = {

    environment.systemPackages = [ pkgs.chromium ];

    virtualisation.oci-containers.containers = {
      openclaw-gateway = {
        image = customImage;
        environment = {
          HOME = "/home/node";
          TERM = "xterm-256color";
          DOCKER_HOST = "unix:///var/run/docker.sock";
          DOCKER_API_VERSION = "1.44";
          OPENCLAW_HOME = "/home/node";
          OPENCLAW_STATE_DIR = "/home/node/.openclaw";
          OPENCLAW_CONFIG_PATH = "/home/node/.openclaw/openclaw.json";
          NODE_COMPILE_CACHE = "/var/tmp/openclaw-compile-cache";
        };
        environmentFiles = [ "/run/openclaw.env" ];
        volumes = [
          "${configDir}:/home/node/.openclaw:rw"
          "/var/run/docker.sock:/var/run/docker.sock"
        ];
        extraOptions = [
          "--init"
          "--network=host"
          "--group-add=${toString dockerGid}"
        ];
        user = "1000:1000";
        cmd = [
          "gateway"
          "--bind"
          "lan"
          "--port"
          (toString openclawPort)
        ];
        autoStart = true;
      };

      openclaw-cli = {
        image = customImage;
        environment = {
          HOME = "/home/node";
          TERM = "xterm-256color";
          BROWSER = "echo";
          DOCKER_HOST = "unix:///var/run/docker.sock";
        };
        environmentFiles = [ "/run/openclaw.env" ];
        volumes = [
          "${configDir}:/home/node/.openclaw:rw"
          "/var/run/docker.sock:/var/run/docker.sock"
        ];
        extraOptions = [
          "--init"
          "--tty"
          "--network=host"
          "--group-add=${toString dockerGid}"
        ];
        cmd = [ "--help" ];
        autoStart = false;
      };
    };

    networking.firewall = {
      allowedTCPPorts = [
        openclawPort
      ];
      allowedUDPPorts = [
        5353 # mDNS
      ];
    };

    services.caddy.proxyServices = {
      "openclaw.${settings.domain}" = openclawPort;
    };

  }; # config
}
