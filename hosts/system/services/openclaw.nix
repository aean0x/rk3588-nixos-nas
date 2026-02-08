# OpenClaw stack (Docker)
{
  config,
  ...
}:
let
  gatewayPort = 18789;
  bridgePort = 18790;
in
{
  # ==================
  # Service user/group
  # ==================

  users.users.openclaw = {
    isSystemUser = true;
    uid = 1540;
    group = "openclaw";
    description = "OpenClaw service user";
    home = "/var/lib/openclaw";
    createHome = true;
  };

  users.groups.openclaw = {
    gid = 1540;
  };

  # ===================
  # Secrets (env files)
  # ===================
  systemd.services.docker-openclaw.preStart = ''
    mkdir -p /var/lib/openclaw/config /var/lib/openclaw/workspace
    chmod 0755 /var/lib/openclaw/config /var/lib/openclaw/workspace
    chown -R openclaw:openclaw /var/lib/openclaw/config /var/lib/openclaw/workspace
    printf '%s\n' \
      "OPENCLAW_GATEWAY_TOKEN=$(cat ${config.sops.secrets.openclaw_gateway_token.path})" \
      "OPENCLAW_GATEWAY_PASSWORD=$(cat ${config.sops.secrets.openclaw_gateway_password.path})" \
      > /run/openclaw.env
    chmod 0600 /run/openclaw.env
  '';

  # ===================
  # Containers
  # ===================
  virtualisation.oci-containers.containers = {

    openclaw = {
      image = "ghcr.io/openclaw/openclaw:latest";
      ports = [
        "${toString gatewayPort}:18789"
        "${toString bridgePort}:18790"
      ];
      volumes = [
        "/var/lib/openclaw/config:/home/node/.openclaw"
        "/var/lib/openclaw/workspace:/home/node/.openclaw/workspace"
      ];
      environment = {
        HOME = "/home/node";
        TERM = "xterm-256color";
      };
      environmentFiles = [ "/run/openclaw.env" ];
      cmd = [
        "node"
        "dist/index.js"
        "gateway"
        "--port"
        "${toString gatewayPort}"
        "--bind"
        "lan"
      ];
      extraOptions = [
        "--init"
        "--user=${toString config.users.users.openclaw.uid}:${toString config.users.groups.openclaw.gid}"
      ];
      autoStart = true;
    };
  };

  # ===================
  # OpenClaw minimal config (tmpfiles)
  # ===================
  systemd.tmpfiles.rules = [
    "d /var/lib/openclaw/config 0755 root root -"
    "d /var/lib/openclaw/workspace 0755 root root -"
    "f /var/lib/openclaw/config/openclaw.json 0644 root root - {\"gateway\":{\"mode\":\"local\"}}"
  ];

  # ===================
  # Firewall
  # ===================
  networking.firewall.allowedTCPPorts = [
    gatewayPort
    bridgePort
  ];
}
