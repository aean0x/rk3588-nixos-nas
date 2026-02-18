# OpenClaw gateway + CLI (Docker)
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

  defaultConfig = {
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
      trustedProxies = [
        "127.0.0.1"
        "::1"
      ];
    };
    commands = {
      native = "auto";
      text = true;
      bash = false;
      config = true;
      restart = true;
    };
    tools = {
      web = {
        search = {
          enabled = true;
          maxResults = 5;
        };
        fetch = {
          enabled = true;
          maxChars = 50000;
        };
      };
    };
    auth = {
      profiles = {
        "xai:default" = {
          provider = "xai";
          mode = "api_key";
        };
      };
    };
    agents = {
      defaults = {
        workspace = "${workspaceDir}";
        model = {
          primary = "xai/grok-4-1-fast-non-reasoning";
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
            binds = [ ];
            setupCommand = "apt-get update && apt-get install -y git uv curl jq nodejs python3-pip";
            readOnlyRoot = true;
            capDrop = [ "ALL" ];
            user = "1000:1000";
            memory = "1g";
            cpus = 1;
          };
          browser = {
            enabled = true;
          };
        };
      };
    };
    models = {
      providers = {
        xai = {
          baseUrl = "https://api.x.ai/v1";
          api = "openai-responses";
          apiKey = "\${XAI_API_KEY}";
          models = [
            {
              id = "grok-4-1-fast-non-reasoning";
              name = "Grok 4.1 Fast";
            }
            {
              id = "grok-4.1-fast-reasoning";
              name = "Grok 4.1 Fast Reasoning";
            }
          ];
        };
      };
    };
    plugins = {
      entries = {
        telegram = {
          enabled = true;
        };
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

  defaultConfigFile = pkgs.writeText "openclaw-defaults.json" (builtins.toJSON defaultConfig);
in
{
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
    path = [
      pkgs.docker
      pkgs.curl
    ];
    script = ''
      docker build -t ${customImage} - <<'EOF'
      FROM ${baseImage}
      USER root
      RUN apt-get update && apt-get install -y curl && \
          curl -fsSL https://download.docker.com/linux/static/stable/aarch64/docker-26.1.3.tgz -o docker.tgz && \
          tar -xzf docker.tgz && \
          mv docker/docker /usr/local/bin/docker && \
          rm -rf docker.tgz docker && \
          chmod +x /usr/local/bin/docker && \
          ln -sf /usr/local/bin/docker /usr/bin/docker && \
          ln -sf /usr/local/bin/docker /bin/docker && \
          rm -rf /var/lib/apt/lists/*
      RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh 2>/dev/null
      RUN chown -R 1000:1000 /home/linuxbrew/.linuxbrew
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
        "18789"
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
        DOCKER_API_VERSION = "1.44";
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

  # Setup directories, config, secrets
  systemd.services.docker-openclaw-gateway.preStart = ''
    set -euo pipefail
    mkdir -p ${configDir} ${workspaceDir}
    chown -R 1000:1000 ${configDir}
    chmod -R 700 ${configDir}

    CONFIG_FILE="${configDir}/openclaw.json"
    if [ -f "$CONFIG_FILE" ]; then
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CONFIG_FILE" ${defaultConfigFile} > /tmp/openclaw-new.json
      mv /tmp/openclaw-new.json "$CONFIG_FILE"
    else
      cp ${defaultConfigFile} "$CONFIG_FILE"
    fi
    chown 1000:1000 "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"

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
