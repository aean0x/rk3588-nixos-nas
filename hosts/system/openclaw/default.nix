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

  # ── Shared container config ──────────────────────────────────
  commonContainer = {
    image = customImage;
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
    environment = {
      HOME = "/home/node";
      TERM = "xterm-256color";
      DOCKER_HOST = "unix:///var/run/docker.sock";
      DOCKER_API_VERSION = "1.44";
      OPENCLAW_HOME = "/home/node";
      OPENCLAW_STATE_DIR = "/home/node/.openclaw";
      OPENCLAW_CONFIG_PATH = "/home/node/.openclaw/openclaw.json";
      NODE_COMPILE_CACHE = "/var/tmp/openclaw-compile-cache";
      OPENCLAW_NO_RESPAWN = "1";
    };
  };
in
{
  imports = [
    ./onedrive.nix
    ./image.nix
    ./deployment.nix
  ];

  options.services.openclaw = {
    secretNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Environment variable names available to OpenClaw containers. Set by sops.nix.";
    };
  };

  config = {

    environment.systemPackages = [ pkgs.chromium ];

    virtualisation.oci-containers.containers = {
      openclaw-gateway = commonContainer // {
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

      openclaw-cli = commonContainer // {
        environment = commonContainer.environment // {
          BROWSER = "echo";
        };
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
