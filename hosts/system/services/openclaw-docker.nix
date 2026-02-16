# OpenClaw (Docker): gateway + CLI containers
{
  config,
  pkgs,
  settings,
  ...
}:
let
  openclawPort = 18789;
  bridgePort = 18790;
  image = "ghcr.io/openclaw/openclaw:latest";
  configDir = "/var/lib/openclaw";
  workspaceDir = "${configDir}/workspace";

  defaultConfig = {
    # -- Gateway ---------------------------------------------------------------
    gateway = {
      port = openclawPort;
      mode = "local";
      bind = "lan";
      auth = {
        mode = "password";
        allowTailscale = true;
      };
      controlUi = {
        enabled = true;
        dangerouslyDisableDeviceAuth = true;
      };
      trustedProxies = [ "127.0.0.1" "::1" ];
    };

    # -- Commands --------------------------------------------------------------
    commands = {
      native = "auto";
      text = true;
      bash = false;
      config = true;
      restart = true;
    };

    # -- Tools -----------------------------------------------------------------
    tools = {
      web = {
        search = { enabled = true; maxResults = 5; };
        fetch = { enabled = true; maxChars = 50000; };
      };
    };

    # -- Auth profiles ---------------------------------------------------------
    auth = {
      profiles = {
        "xai:default" = { provider = "xai"; mode = "api_key"; };
      };
    };

    agents = {
      defaults = {
        workspace = "~/.openclaw/workspace";
        model = {
          primary = "xai/grok-4.1-fast";
          fallbacks = [ "xai/grok-4.1-fast-reasoning" ];
        };
        compaction = {
          mode = "default";
          memoryFlush = {
            enabled = true;
            softThresholdTokens = 40000;
            prompt = "Extract key decisions, state changes, lessons, blockers to memory/YYYY-MM-DD.md. Format: ## [HH:MM] Topic. Skip routine work. NO_FLUSH if nothing important.";
            systemPrompt = "Compacting session context. Extract only what's worth remembering. No fluff.";
          };
        };
        contextPruning = {
          mode = "cache-ttl";
          ttl = "12h";
          keepLastAssistants = 3;
          softTrimRatio = 0.3;
          hardClearRatio = 0.5;
        };
        sandbox = {
          mode = "all";
          scope = "agent";
          workspaceAccess = "rw";
          docker = {
            network = "bridge";
            binds = [];
            setupCommand = "apt-get update && apt-get install -y git curl jq nodejs python3-pip";
            readOnlyRoot = true;
            capDrop = [ "ALL" ];
            user = "1000:1000";
            memory = "1g";
            cpus = 1;
          };
          browser = { enabled = true; };
          tools = {
            sandbox = { tools = { allow = [ "exec" "read" "write" "edit" ]; }; };
            elevated = false;
          };
        };
      };
    };
    models = {
      providers = {
        xai = {
          provider = "xai";
          baseUrl = "https://api.x.ai/v1";
          api = "openai-responses";
          apiKey = "\${XAI_API_KEY}";
          models = [
            { id = "grok-4.1-fast"; name = "Grok 4.1 Fast"; }
            { id = "grok-4.1-fast-reasoning"; name = "Grok 4.1 Fast Reasoning"; }
          ];
        };
      };
    };
    plugins = {
      entries = {
        telegram = { enabled = true; };
      };
    };
    channels = {
      telegram = {
        enabled = true;
        dmPolicy = "pairing";
        groupPolicy = "allowlist";
        streamMode = "partial";
      };
    };
    messages = {
      ackReactionScope = "group-mentions";
      tts = {
        auto = "inbound";
        provider = "edge";
        edge = {
          enabled = true;
          voice = "en-GB-RyanNeural";
        };
      };
    };
    logging = {
      redactSensitive = "tools";
    };
  };

  defaultConfigJson = builtins.toJSON defaultConfig;
in
{
  # ===================
  # Containers
  # ===================
  virtualisation.oci-containers.containers = {
    # Gateway (persistent)
    openclaw-gateway = {
      image = image;
      environment = {
        HOME = "/home/node";
        TERM = "xterm-256color";
      };
      environmentFiles = [ "/run/openclaw.env" ];
      volumes = [ "${configDir}:/home/node/.openclaw:rw" ];
      ports = [
        "${toString openclawPort}:18789"
        "${toString bridgePort}:18790"
      ];
      extraOptions = [
        "--init"
        "--restart=unless-stopped"
      ];
      cmd = [
        "node"
        "dist/index.js"
        "gateway"
        "--bind"
        "lan"
        "--port"
        "18789"
      ];
      autoStart = true;
    };

    # CLI (on-demand exec, not auto-restarted)
    openclaw-cli = {
      image = image;
      environment = {
        HOME = "/home/node";
        TERM = "xterm-256color";
        BROWSER = "echo";
      };
      environmentFiles = [ "/run/openclaw.env" ];
      volumes = [ "${configDir}:/home/node/.openclaw:rw" ];
      extraOptions = [
        "--init"
        "--tty"
      ];
      entrypoint = "node";
      cmd = [ "dist/index.js" ];
      autoStart = false;
    };
  };

  # ===================
  # One-time migration from native openclaw (move old data, chown onedrive)
  # ===================
  systemd.services.openclaw-migration = {
    description = "One-time migration from native OpenClaw to Docker";
    before = [ "docker-openclaw-gateway.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    path = [ pkgs.rsync ];
    script = ''
      set -euo pipefail
      MARKER="${configDir}/.docker_migrated"
      if [ -f "$MARKER" ]; then
        exit 0
      fi

      BACKUP_DIR="${configDir}/backup"
      LEGACY_OPENCLAW_HOME="/home/openclaw/.openclaw"

      mkdir -p ${configDir} ${workspaceDir} "$BACKUP_DIR"

      # Copy old native openclaw data to backup if it exists (rsync preserves perms)
      if [ -d "$LEGACY_OPENCLAW_HOME" ] && [ ! -L "$LEGACY_OPENCLAW_HOME" ]; then
        ${pkgs.rsync}/bin/rsync -a "$LEGACY_OPENCLAW_HOME/" "$BACKUP_DIR/.openclaw.old/"
      fi

      # Chown onedrive sync folder to UID 1000 if it exists
      if [ -d "${workspaceDir}/onedrive" ]; then
        chown -R 1000:1000 "${workspaceDir}/onedrive"
      fi

      chown -R 1000:1000 ${configDir}
      chmod -R 700 ${configDir}

      touch "$MARKER"
      chown 1000:1000 "$MARKER"
      chmod 0600 "$MARKER"
    '';
  };

  # ===================
  # Secrets injector + config merge (preStart for gateway)
  # ===================
  systemd.services.docker-openclaw-gateway.preStart = ''
    set -euo pipefail

    # Create directories
    mkdir -p ${configDir} ${workspaceDir}

    chown -R 1000:1000 ${configDir}
    chmod -R 700 ${configDir}

    # Merge or create config
    CONFIG_FILE="${configDir}/openclaw.json"
    if [ -f "$CONFIG_FILE" ]; then
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CONFIG_FILE" <(echo '${defaultConfigJson}') > /tmp/openclaw-new.json
      mv /tmp/openclaw-new.json "$CONFIG_FILE"
    else
      echo '${defaultConfigJson}' > "$CONFIG_FILE"
    fi
    chown 1000:1000 "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"

    # Write API keys to environment file (from SOPS secrets)
    BRAVE_KEY="$(cat ${config.sops.secrets.brave_search_api_key.path})"
    printf '%s\n' \
      "OPENCLAW_GATEWAY_TOKEN=$(cat ${config.sops.secrets.openclaw_gateway_token.path})" \
      "OPENCLAW_GATEWAY_PASSWORD=$(cat ${config.sops.secrets.openclaw_gateway_password.path})" \
      "XAI_API_KEY=$(cat ${config.sops.secrets.xai_api_key.path})" \
      "OPENROUTER_API_KEY=$(cat ${config.sops.secrets.openrouter_api_key.path})" \
      "OPENAI_API_KEY=$(cat ${config.sops.secrets.openrouter_api_key.path})" \
      "ANTHROPIC_API_KEY=$(cat ${config.sops.secrets.anthropic_api_key.path})" \
      "BRAVE_API_KEY=$BRAVE_KEY" \
      "BRAVE_SEARCH_API_KEY=$BRAVE_KEY" \
      "TELEGRAM_BOT_TOKEN=$(cat ${config.sops.secrets.telegram_bot_token.path})" \
      > /run/openclaw.env
    chmod 0640 /run/openclaw.env
  '';

  # ===================
  # Refresh service (pull + restart)
  # ===================
  systemd.services.openclaw-refresh = {
    description = "Pull latest OpenClaw image and refresh containers";
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${pkgs.docker}/bin/docker pull ${image} || true
      ${pkgs.docker}/bin/docker image prune -f --filter "until=168h"
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

  # ===================
  # Firewall
  # ===================
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
    "openclaw.rocknas.local" = openclawPort;
  };
}
