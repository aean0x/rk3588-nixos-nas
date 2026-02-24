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
      # Clean apt cache first + update (robust against partial state)
      RUN rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* && \
          apt-get update && \
          apt-get install -y --no-install-recommends \
            git curl jq nodejs python3-pip build-essential ca-certificates && \
          rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
      # Install uv properly (official way, pinned version avoids surprises)
      RUN curl -LsSf https://astral.sh/uv/0.5.0/install.sh | sh && \
          rm -rf /root/.cache/uv  # optional cleanup
      # Install Docker CLI binary (arm64 variant for rocknas)
      RUN curl -fsSL https://download.docker.com/linux/static/stable/aarch64/docker-26.1.3.tgz | \
          tar -xzf - --strip-components=1 -C /usr/local/bin docker/docker && \
          chmod +x /usr/local/bin/docker && \
          ln -sf /usr/local/bin/docker /usr/bin/docker
      # Make node user member of docker group (for docker.sock access)
      RUN groupadd -g 131 docker 2>/dev/null || true && \
          usermod -aG docker node
      # Ensure docker binary is executable by non-root (redundant after chmod +x above, but safe)
      RUN chmod 755 /usr/local/bin/docker
      # Pre-create dirs for non-root agent + fix perms
      RUN mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial \
                   /home/node/.cache/uv /home/node/.local/share/uv \
                   /tmp /dev/shm && \
          chown -R 1000:1000 /home/node /tmp && \
          chmod -R 1777 /tmp /dev/shm && \
          chown -R _apt:root /var/lib/apt /var/cache/apt 2>/dev/null || true
      # Your openclaw wrapper
      RUN printf '#!/bin/sh\nexec node /app/dist/index.js "$@"\n' > /usr/local/bin/openclaw && \
          chmod +x /usr/local/bin/openclaw
      # Optional: global git safe if cloning inside containers later
      RUN git config --global --add safe.directory '*'
      USER 1000:1000
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

  # Recover from in-process restarts (SIGUSR1 / /config edits)
  systemd.services.docker-openclaw-gateway.serviceConfig = {
    Restart = pkgs.lib.mkForce "always";
    RestartSec = "5s";
  };

  # Deploy config + secrets (runs once on rebuild, not on container restart)
  systemd.services.openclaw-setup = {
    description = "Deploy OpenClaw config and secrets";
    wantedBy = [ "multi-user.target" ];
    before = [ "docker-openclaw-gateway.service" ];
    requiredBy = [ "docker-openclaw-gateway.service" ];
    after = [ "sops-nix.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      mkdir -p ${configDir} ${workspaceDir}
      mkdir -p /home/node
      ln -sfn ${configDir} /home/node/.openclaw

      # Deploy Main agent (everything from hosts/system/openclaw/workspace/)
      # This includes sub-agents/ folder which contains specific configs
      cp -r ${./workspace}/* "${workspaceDir}/"
      mkdir -p "${workspaceDir}/memory"

      # Ensure sub-agents directories exist and have memory folders
      # We iterate over the folders that were copied into workspace-main/sub-agents
      for agent in researcher communicator controller; do
        agent_dir="${workspaceDir}/sub-agents/$agent"
        mkdir -p "$agent_dir/memory"

        # Link shared context from main workspace if they exist and don't overwrite existing files
        for shared in SOUL.md STYLE.md USER.md; do
            if [ -f "${workspaceDir}/$shared" ] && [ ! -f "$agent_dir/$shared" ]; then
                ln -s "${workspaceDir}/$shared" "$agent_dir/$shared"
            fi
        done
      done

      chown -R 1000:1000 ${configDir}
      chmod -R 700 ${configDir}

      CONFIG_FILE="${configDir}/openclaw.json"
      cp ${defaultConfigFile} "$CONFIG_FILE"

      BROWSERLESS_TOKEN="$(cat ${config.sops.secrets.browserless_api_token.path})"
      ${pkgs.gnused}/bin/sed -i "s|\''${BROWSERLESS_API_TOKEN}|$BROWSERLESS_TOKEN|g" "$CONFIG_FILE"

      chown 1000:${toString dockerGid} "$CONFIG_FILE"
      chmod 0660 "$CONFIG_FILE"

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
        "TELEGRAM_ADMIN_ID=$(cat ${config.sops.secrets.telegram_admin_id.path})" \
        "GOOGLE_API_KEY=$(cat ${config.sops.secrets.google_api_key.path})" \
        "GEMINI_API_KEY=$(cat ${config.sops.secrets.google_api_key.path})" \
        > /run/openclaw.env
      chmod 0640 /run/openclaw.env
    '';
  };

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
