# OpenClaw gateway + CLI (Docker)
# Custom image built on pinned upstream base via dockerTools.pullImage
#
# To update the base image:
#   1. Get digest: docker pull ghcr.io/phioranex/openclaw-docker:latest && \
#                  docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/phioranex/openclaw-docker:latest
#   2. Get sha256: nix-prefetch-docker --image-name ghcr.io/phioranex/openclaw-docker --image-tag latest --os linux --arch arm64
#   3. Update imageDigest and sha256 below, then rebuild
{
  config,
  pkgs,
  settings,
  ...
}:
let
  openclawPort = 18789;
  bridgePort = 18790;
  configDir = "/var/lib/openclaw";
  workspaceDir = "${configDir}/workspace";

  # Pinned base image - update hashes to upgrade
  baseImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/phioranex/openclaw-docker";
    imageDigest = "sha256:384cf56cef20181a2c60784f965f4ff93cf833dee51458c700c437cfc4106a46"; # docker inspect --format '{{index .RepoDigests 0}}'
    sha256 = "36cd52e7c30f9e8472bf1f9ae16f43c0fd39e0590fcbcf821883ed87dba7779b"; # nix-prefetch-docker output
    os = "linux";
    arch = "arm64";
  };

  customImage = pkgs.dockerTools.buildLayeredImage {
    name = "openclaw-custom";
    tag = "latest";
    fromImage = baseImage;
    contents = [
      pkgs.docker-client
      pkgs.git
      pkgs.curl
      pkgs.jq
      pkgs.nodejs
      pkgs.python3Full
      pkgs.uv
    ];
    config = {
      User = "1000:1000";
      Env = [
        "HOME=/home/node"
        "TERM=xterm-256color"
        "DOCKER_HOST=unix:///var/run/docker.sock"
        "DOCKER_API_VERSION=1.44"
      ];
    };
  };

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
        workspace = "~/.openclaw/workspace";
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
  # Load custom image before container starts
  systemd.services.docker-load-openclaw = {
    description = "Load custom OpenClaw image";
    before = [ "docker-openclaw-gateway.service" ];
    wantedBy = [ "docker-openclaw-gateway.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.docker}/bin/docker load -i ${customImage}";
    };
  };

  virtualisation.oci-containers.containers = {
    openclaw-gateway = {
      image = "openclaw-custom:latest";
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

    openclaw-cli = {
      image = "openclaw-custom:latest";
      environment = {
        BROWSER = "echo";
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
      entrypoint = "node";
      cmd = [ "dist/index.js" ];
      autoStart = false;
    };
  };

  # Setup directories, config, secrets, and docker group access
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

    ${pkgs.docker}/bin/docker exec -u root openclaw-gateway sh -c "
      DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
      groupadd -g \$DOCKER_GID docker || true
      usermod -aG docker node
      chown -R node:node /home/node/.openclaw
    " || true
  '';

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
