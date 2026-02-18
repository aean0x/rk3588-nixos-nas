# OpenClaw (non-root gateway + sandboxes via docker.sock)
# Custom image built at runtime on the device via docker build.
# This avoids dockerTools.pullImage cross-arch sandbox issues.
{
  config,
  pkgs,
  settings,
  ...
}:
let
  openclawPort = 18789;
  bridgePort = 18790;
  baseImage = "ghcr.io/phioranex/openclaw-docker:latest";
  customImage = "openclaw-custom:latest";
  configDir = "/var/lib/openclaw";
  workspaceDir = "${configDir}/workspace";

  dockerGid =
    if (config.users.groups ? docker && config.users.groups.docker.gid != null) then
      config.users.groups.docker.gid
    else
      131;

  defaultConfigFile = ./openclaw.json;

  workspaceFiles = {
    "AGENTS.md" = ./workspace/AGENTS.md;
    "SOUL.md" = ./workspace/SOUL.md;
    "STYLE.md" = ./workspace/STYLE.md;
  };
in
{
  imports = [ ./onedrive.nix ];

  # Build custom image on-device (native docker build, no qemu)
  systemd.services.openclaw-builder = {
    description = "Build custom OpenClaw image with Docker CLI";
    before = [
      "docker-openclaw-gateway.service"
      "docker-openclaw-cli.service"
    ];
    requiredBy = [
      "docker-openclaw-gateway.service"
      "docker-openclaw-cli.service"
    ];
    path = [ pkgs.docker ];
    script = ''
            docker build -t ${customImage} - <<'EOF'
      FROM ${baseImage}
      USER root
      RUN apt-get update && apt-get install -y curl && \
          curl -fsSL https://download.docker.com/linux/static/stable/aarch64/docker-26.1.3.tgz | tar -xzf - --strip-components=1 -C /usr/local/bin docker/docker && \
          chmod +x /usr/local/bin/docker && ln -sf /usr/local/bin/docker /usr/bin/docker && \
          curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh && \
          rm -rf /var/lib/apt/lists/*
      RUN chown -R 1000:1000 /home/linuxbrew/.linuxbrew /home/node 2>/dev/null || true
      USER 1000
      EOF
    '';
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "300";
    };
  };

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

  # Setup directories, config, workspace dotfiles, secrets
  systemd.services.docker-openclaw-gateway.preStart =
    let
      secretsScript = pkgs.writeShellScript "openclaw-prestart" ''
        set -euo pipefail
        mkdir -p ${configDir} ${workspaceDir}

        chown -R 1000:1000 ${configDir}
        chmod -R 700 ${configDir}

        # TODO: re-enable workspace dotfile deployment (see workspaceFiles in let block)

        # Symlink so Docker daemon resolves openclaw's default paths from host
        mkdir -p /home/node
        ln -sfn ${configDir} /home/node/.openclaw

        CONFIG_FILE="${configDir}/openclaw.json"
        if [ -f "$CONFIG_FILE" ]; then
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CONFIG_FILE" ${defaultConfigFile} > /tmp/openclaw-new.json
          mv /tmp/openclaw-new.json "$CONFIG_FILE"
        else
          cp ${defaultConfigFile} "$CONFIG_FILE"
        fi
        chown 1000:1000 "$CONFIG_FILE"
        chmod 0600 "$CONFIG_FILE"

        printf '%s\n' \
          "OPENCLAW_GATEWAY_TOKEN=$(cat ${config.sops.secrets.openclaw_gateway_token.path})" \
          "OPENCLAW_GATEWAY_PASSWORD=$(cat ${config.sops.secrets.openclaw_gateway_password.path})" \
          "XAI_API_KEY=$(cat ${config.sops.secrets.xai_api_key.path})" \
          "OPENROUTER_API_KEY=$(cat ${config.sops.secrets.openrouter_api_key.path})" \
          "OPENAI_API_KEY=$(cat ${config.sops.secrets.openrouter_api_key.path})" \
          "ANTHROPIC_API_KEY=$(cat ${config.sops.secrets.anthropic_api_key.path})" \
          "BRAVE_API_KEY=$(cat ${config.sops.secrets.brave_search_api_key.path})" \
          "TELEGRAM_BOT_TOKEN=$(cat ${config.sops.secrets.telegram_bot_token.path})" \
          "GOOGLE_PLACES_API_KEY=$(cat ${config.sops.secrets.google_places_api_key.path})" \
          "BROWSERLESS_API_TOKEN=$(cat ${config.sops.secrets.browserless_api_token.path})" \
          "MATON_API_KEY=$(cat ${config.sops.secrets.maton_api_key.path})" \
          "HA_TOKEN=$(cat ${config.sops.secrets.ha_token.path})" \
          "HA_URL=$(cat ${config.sops.secrets.ha_url.path})" \
          "GOOGLE_API_KEY=$(cat ${config.sops.secrets.google_api_key.path})" \
          "GEMINI_API_KEY=$(cat ${config.sops.secrets.google_api_key.path})" \
          > /run/openclaw.env
        chmod 0640 /run/openclaw.env
      '';
    in
    toString secretsScript;

  # Weekly image refresh
  systemd.services.openclaw-refresh = {
    description = "Pull latest OpenClaw image and rebuild custom image";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.docker}/bin/docker pull ${baseImage} || true
      ${pkgs.docker}/bin/docker image prune -f --filter "until=168h"
      ${pkgs.systemd}/bin/systemctl restart openclaw-builder.service
      ${pkgs.systemd}/bin/systemctl try-restart docker-openclaw-gateway.service
    '';
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
  };

  systemd.timers.openclaw-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "3600";
    };
  };

  networking.firewall = {
    allowedTCPPorts = [
      openclawPort
      bridgePort
    ];
    allowedUDPPorts = [
      5353 # mDNS
    ];
  };

  services.caddy.proxyServices = {
    "openclaw.${settings.domain}" = openclawPort;
  };
}
