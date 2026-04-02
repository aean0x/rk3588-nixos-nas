# OpenClaw (non-root gateway + sandboxes via docker.sock)
# Custom image built at runtime on the device via docker build.
# This avoids dockerTools.pullImage cross-arch sandbox issues.
{
  config,
  pkgs,
  lib,
  settings,
  ...
}:
let
  oc = {
    env = name: "\${${name}}";
    port = 18789;
    configDir = "/var/lib/openclaw";
    workspaceDir = "/var/lib/openclaw/workspace";

    # Docker config
    gatewayBaseImage = "ghcr.io/phioranex/openclaw-docker:latest";
    gatewayImage = "openclaw-custom:latest";
    sandboxBaseImage = "node:22-bookworm-slim";
    sandboxImage = "openclaw-sandbox-custom:latest";
    dockerGid =
      if (config.users.groups ? docker && config.users.groups.docker.gid != null) then
        config.users.groups.docker.gid
      else
        131;

    # Shared container environment
    containerEnv = {
      HOME = "/home/node";
      OPENCLAW_HOME = "/home/node";
      OPENCLAW_STATE_DIR = "/home/node/.openclaw";
      OPENCLAW_CONFIG_PATH = "/home/node/.openclaw/openclaw.json";
    };
  };

  openclawConfig = import ./config.nix {
    inherit
      pkgs
      lib
      settings
      oc
      ;
  };

  # ── Shared container config ──────────────────────────────────
  commonContainer = {
    image = oc.gatewayImage;
    volumes = [
      "${oc.configDir}:/home/node/.openclaw:rw"
      "/run/openclaw.env:/home/node/.openclaw/.env:ro"
      "/var/run/docker.sock:/var/run/docker.sock"
    ];
    extraOptions = [
      "--init"
      "--network=host"
      "--group-add=${toString oc.dockerGid}"
    ];
    environment = oc.containerEnv // {
      TERM = "xterm-256color";
      DOCKER_HOST = "unix:///var/run/docker.sock";
      DOCKER_API_VERSION = "1.44";
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

  options.services.openclaw = { };

  config = {
    # Expose constants and config object for submodules (avoids double evaluation)
    _module.args.oc = oc;
    _module.args.openclawConfig = openclawConfig;

    environment.systemPackages = [ pkgs.chromium ];

    virtualisation.oci-containers.containers = {
      openclaw-gateway = commonContainer // {
        user = "1000:1000";
        cmd = [
          "gateway"
          "--bind"
          "lan"
          "--port"
          (toString oc.port)
        ];
        autoStart = true;
      };
    };

    networking.firewall = {
      allowedTCPPorts = [
        oc.port
      ];
      allowedUDPPorts = [
        5353 # mDNS
      ];
    };

    services.caddy.proxyServices = {
      "openclaw.${settings.domain}" = oc.port;
    };

  };
}
