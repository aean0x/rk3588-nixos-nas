# OpenClaw stack (Docker)
# Config is deep-merged into openclaw.json via preStart — declared keys always win,
# runtime state (meta, wizard, devices, sessions) survives across restarts.
# To inspect live config: ./deploy ssh "sudo cat /var/lib/openclaw/config/openclaw.json"
{
  config,
  pkgs,
  ...
}:
let
  gatewayPort = 18789;
  bridgePort = 18790;

  # ===========================================================================
  # OpenClaw configuration — edit this attrset, remote-switch to apply.
  # Secrets (tokens, passwords, API keys) are injected via env vars from SOPS.
  # ===========================================================================
  openclawConfig = {

    # -- Gateway ---------------------------------------------------------------
    gateway = {
      port = gatewayPort;
      mode = "local";
      bind = "lan";
      auth = {
        mode = "password"; # reads OPENCLAW_GATEWAY_PASSWORD env
        allowTailscale = true;
      };
      controlUi = {
        enabled = true;
        dangerouslyDisableDeviceAuth = true; # skip device pairing on LAN/tailscale
      };
      trustedProxies = [
        "127.0.0.1"
        "::1"
        "172.17.0.1" # Docker bridge gateway
      ];
      tailscale = {
        mode = "off"; # Tailscale runs natively on host, not in container
      };
    };

    # -- Browser ---------------------------------------------------------------
    browser = {
      executablePath = "/usr/local/bin/chrome-wrapper";
      headless = true;
      noSandbox = true;
    };

    # -- Agent defaults --------------------------------------------------------
    agents = {
      defaults = {
        model = {
          primary = "openrouter/google/gemini-3-flash-preview";
          fallbacks = [
            "openrouter/openai/gpt-4.1-nano"
            "openrouter/openai/gpt-4.1-mini"
          ];
        };
        models = {
          "openrouter/arcee-ai/trinity-mini:free" = {
            alias = "trinity";
          };
          "openrouter/anthropic/claude-opus-4.6" = {
            alias = "opus";
          };
          "openrouter/anthropic/claude-sonnet-4.5" = {
            alias = "sonnet";
          };
          "openrouter/anthropic/claude-haiku-4.5" = {
            alias = "haiku";
          };
          "openrouter/google/gemini-3-pro-preview" = {
            alias = "gemini-pro";
          };
          "openrouter/google/gemini-3-flash-preview" = {
            alias = "gemini-flash";
          };
          "openrouter/google/gemini-2.5-flash" = {
            alias = "gemini-2.5";
          };
          "openrouter/x-ai/grok-4.1-fast" = {
            alias = "grok";
          };
          "openrouter/openai/gpt-4.1-mini" = {
            alias = "gpt-mini";
          };
          "openrouter/openai/gpt-4.1-nano" = {
            alias = "gpt-nano";
          };
        };
        workspace = "/home/node/.openclaw/workspace";

        memorySearch = {
          sources = [
            "memory"
            "sessions"
          ];
          experimental = {
            sessionMemory = true;
          };
          provider = "openai";
          model = "text-embedding-3-small";
          remote = {
            baseUrl = "https://openrouter.ai/api/v1";
          };
        };

        cliBackends = {
          google-workspace = {
            command = "google-workspace-mcp";
            output = "json";
            env = {
              XDG_CONFIG_HOME = "/home/node/.openclaw";
              GOOGLE_DRIVE_OAUTH_CREDENTIALS = "/home/node/.openclaw/google-workspace-mcp/credentials.json";
              GOOGLE_DRIVE_TOKENS = "/home/node/.openclaw/google-workspace-mcp/tokens.json";
            };
          };
          qmd = {
            command = "/home/node/.bun/bin/bunx";
            args = [
              "qmd"
              "mcp"
            ];
          };
        };

        contextPruning = {
          mode = "cache-ttl";
          ttl = "6h";
          keepLastAssistants = 3;
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

        heartbeat = {
          model = "openrouter/arcee-ai/trinity-mini:free";
        };

        maxConcurrent = 4;
        subagents = {
          maxConcurrent = 8;
          model = "gemini-flash";
        };
      };
      list = [
        {
          id = "main";
          default = true;
        }
      ];
    };

    # -- Plugins ---------------------------------------------------------------
    plugins = {
      entries = {
        telegram = {
          enabled = true;
        };
      };
    };

    # -- Auth profiles ---------------------------------------------------------
    # Tokens live in env vars (OPENROUTER_API_KEY, ANTHROPIC_API_KEY, etc.)
    # or in /home/node/.openclaw/credentials/ (volume-mounted)
    auth = {
      profiles = {
        "openrouter:default" = {
          provider = "openrouter";
          mode = "api_key";
        };
        "anthropic:default" = {
          provider = "anthropic";
          mode = "api_key";
        };
      };
    };

    # -- Custom model providers ------------------------------------------------
    # models = {
    #   mode = "merge";
    #   providers = {
    #     synthetic = {
    #       baseUrl = "https://api.synthetic.new/anthropic";
    #       api = "anthropic-messages";
    #       models = [
    #         {
    #           id = "hf:zai-org/GLM-4.7"; name = "GLM-4.7";
    #           reasoning = false; input = [ "text" ];
    #           cost = { input = 0; output = 0; cacheRead = 0; cacheWrite = 0; };
    #           contextWindow = 198000; maxTokens = 128000;
    #         }
    #         {
    #           id = "hf:moonshotai/Kimi-K2.5"; name = "Kimi K2.5";
    #           reasoning = true; input = [ "text" ];
    #           cost = { input = 0; output = 0; cacheRead = 0; cacheWrite = 0; };
    #           contextWindow = 256000; maxTokens = 8192;
    #         }
    #       ];
    #     };
    #   };
    # };

    # -- Tools -----------------------------------------------------------------
    tools = {
      web = {
        search = {
          enabled = true;
        }; # uses BRAVE_SEARCH_API_KEY env if set
        fetch = {
          enabled = true;
        };
      };
    };

    # -- Channels --------------------------------------------------------------
    # Uncomment and configure as needed. Bot tokens come from env vars.
    channels = {
      telegram = {
        enabled = true;
        dmPolicy = "pairing";
        groupPolicy = "allowlist";
        streamMode = "partial";
        # botToken from TELEGRAM_BOT_TOKEN env
      };
      #   discord = {
      #     enabled = true;
      #     groupPolicy = "allowlist";
      #     dm = { enabled = true; policy = "allowlist"; allowFrom = [ "YOUR_USER_ID" ]; };
      #     # token from DISCORD_BOT_TOKEN env
      #   };
    };

    # -- Messages --------------------------------------------------------------
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

    # -- Logging ---------------------------------------------------------------
    logging = {
      redactSensitive = "tools";
    };

    # -- Commands --------------------------------------------------------------
    commands = {
      native = "auto";
      nativeSkills = "auto";
    };
  };

  configFile = pkgs.writeText "openclaw-desired.json" (builtins.toJSON openclawConfig);

  # Chromium system deps required by Playwright (installed as root inside container on each start)
  browserDeps = [
    "libnspr4"
    "libnss3"
    "libatk1.0-0"
    "libatk-bridge2.0-0"
    "libdbus-1-3"
    "libcups2"
    "libxkbcommon0"
    "libatspi2.0-0"
    "libxcomposite1"
    "libxdamage1"
    "libxfixes3"
    "libxrandr2"
    "libgbm1"
    "libasound2"
  ];
in
{
  services.caddy.proxyServices = {
    "openclaw.rocknas.local" = gatewayPort;
  };

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
  # Secrets + config injection
  # ===================
  systemd.services.docker-openclaw.preStart = ''
    mkdir -p /var/lib/openclaw/config /var/lib/openclaw/workspace \
             /var/lib/openclaw/npm-cache /var/lib/openclaw/npm-global /var/lib/openclaw/browsers \
             /var/lib/openclaw/bun /var/lib/openclaw/qmd-cache /var/lib/openclaw/dot-config
    chown -R openclaw:openclaw /var/lib/openclaw



    CONF=/var/lib/openclaw/config/openclaw.json
    if [ -f "$CONF" ]; then
      # Remove invalid keys that persist from previous configs
      ${pkgs.jq}/bin/jq 'del(.browser.launchArgs)' "$CONF" > "$CONF.clean" && mv "$CONF.clean" "$CONF"
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CONF" ${configFile} > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    else
      cp ${configFile} "$CONF"
    fi
    chown openclaw:openclaw "$CONF"
    chmod 0700 /var/lib/openclaw/config
    chmod 0600 "$CONF"

    # Write Google Workspace MCP credentials from SOPS
    GWS_DIR=/var/lib/openclaw/config/google-workspace-mcp
    mkdir -p "$GWS_DIR"
    GWS_ID="$(cat ${config.sops.secrets.google_workspace_client_id.path})"
    GWS_SECRET="$(cat ${config.sops.secrets.google_workspace_client_secret.path})"
    printf '{"installed":{"client_id":"%s","project_id":"clawdbot-486907","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","auth_provider_x509_cert_url":"https://www.googleapis.com/oauth2/v1/certs","client_secret":"%s","redirect_uris":["http://localhost"]}}\n' \
      "$GWS_ID" "$GWS_SECRET" > "$GWS_DIR/credentials.json"
    chown openclaw:openclaw "$GWS_DIR/credentials.json"

    BRAVE_KEY="$(cat ${config.sops.secrets.brave_search_api_key.path})"
    printf '%s\n' \
      "OPENCLAW_GATEWAY_TOKEN=$(cat ${config.sops.secrets.openclaw_gateway_token.path})" \
      "OPENCLAW_GATEWAY_PASSWORD=$(cat ${config.sops.secrets.openclaw_gateway_password.path})" \
      "OPENROUTER_API_KEY=$(cat ${config.sops.secrets.openrouter_api_key.path})" \
      "OPENAI_API_KEY=$(cat ${config.sops.secrets.openrouter_api_key.path})" \
      "ANTHROPIC_API_KEY=$(cat ${config.sops.secrets.anthropic_api_key.path})" \
      "BRAVE_API_KEY=$BRAVE_KEY" \
      "BRAVE_SEARCH_API_KEY=$BRAVE_KEY" \
      "TELEGRAM_BOT_TOKEN=$(cat ${config.sops.secrets.telegram_bot_token.path})" \
      > /run/openclaw.env
    chmod 0600 /run/openclaw.env
  '';

  # Installs Chromium deps + Playwright browser inside the container after it starts.
  # Separate oneshot because ExecStart (docker start --attach) blocks until container exits.
  systemd.services.openclaw-browser-setup = {
    description = "Install browser deps in OpenClaw container";
    after = [ "docker-openclaw.service" ];
    requires = [ "docker-openclaw.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RestartSec = "10s";
      Restart = "on-failure";
      StartLimitBurst = 3;
    };
    script = ''
      # Wait for container to be fully up and accepting exec commands
      sleep 5
      for _ in $(seq 1 30); do
        if ${pkgs.docker}/bin/docker exec openclaw true 2>/dev/null; then
          break
        fi
        sleep 3
      done

      # Symlink openclaw CLI onto PATH
      ${pkgs.docker}/bin/docker exec --user root openclaw \
        ln -sf /app/openclaw.mjs /usr/local/bin/openclaw

      # Create Chrome wrapper to disable crashpad
      ${pkgs.docker}/bin/docker exec --user root openclaw \
        bash -c 'printf "#!/bin/sh\\nexec /home/node/.cache/ms-playwright/chromium-1208/chrome-linux/chrome --disable-crashpad \"\$@\"\\n" > /usr/local/bin/chrome-wrapper && chmod +x /usr/local/bin/chrome-wrapper'

      # Install Chromium system deps
      ${pkgs.docker}/bin/docker exec --user root openclaw \
        apt-get update -qq > /dev/null 2>&1
      ${pkgs.docker}/bin/docker exec --user root openclaw \
        apt-get install -y --no-install-recommends -qq ${builtins.concatStringsSep " " browserDeps} > /dev/null 2>&1

      if ! ${pkgs.docker}/bin/docker exec openclaw test -d /home/node/.cache/ms-playwright/chromium-1208 2>/dev/null; then
        ${pkgs.docker}/bin/docker exec openclaw \
          node /app/node_modules/playwright-core/cli.js install chromium
      fi

      # Install Bun (aarch64 binary, persisted via volume mount)
      if ! ${pkgs.docker}/bin/docker exec openclaw test -f /home/node/.bun/bin/bun 2>/dev/null; then
        ${pkgs.docker}/bin/docker exec openclaw \
          bash -c 'export BUN_INSTALL=/home/node/.bun && curl -fsSL https://bun.sh/install | bash'
      fi

      # Install QMD (persisted via bun volume mount)
      if ! ${pkgs.docker}/bin/docker exec openclaw test -f /home/node/.bun/bin/qmd 2>/dev/null; then
        ${pkgs.docker}/bin/docker exec openclaw \
          /home/node/.bun/bin/bun install -g github:tobi/qmd
      fi

      # Install QMD skill in OpenClaw (idempotent)
      ${pkgs.docker}/bin/docker exec openclaw \
        /usr/local/bin/openclaw skills install clawhub.ai/steipete/qmd 2>/dev/null || true
    '';
  };

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
        "/var/lib/openclaw/npm-cache:/home/node/.npm"
        "/var/lib/openclaw/npm-global:/home/node/.npm-global"
        "/var/lib/openclaw/browsers:/home/node/.cache/ms-playwright"
        "/var/lib/openclaw/bun:/home/node/.bun"
        "/var/lib/openclaw/qmd-cache:/home/node/.cache/qmd"
        "/var/lib/openclaw/dot-config:/home/node/.config"
      ];
      environment = {
        HOME = "/home/node";
        TERM = "xterm-256color";
        NPM_CONFIG_PREFIX = "/home/node/.npm-global";
        PATH = "/home/node/.bun/bin:/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        PLAYWRIGHT_BROWSERS_PATH = "/home/node/.cache/ms-playwright";
      };
      environmentFiles = [ "/run/openclaw.env" ];
      cmd = [
        "node"
        "dist/index.js"
        "gateway"
      ];
      extraOptions = [
        "--init"
        "--user=${toString config.users.users.openclaw.uid}:${toString config.users.groups.openclaw.gid}"
      ];
      autoStart = true;
    };

    openclaw-cli = {
      image = "ghcr.io/openclaw/openclaw:latest";
      volumes = [
        "/var/lib/openclaw/config:/home/node/.openclaw"
        "/var/lib/openclaw/workspace:/home/node/.openclaw/workspace"
        "/var/lib/openclaw/npm-cache:/home/node/.npm"
        "/var/lib/openclaw/npm-global:/home/node/.npm-global"
        "/var/lib/openclaw/browsers:/home/node/.cache/ms-playwright"
        "/var/lib/openclaw/bun:/home/node/.bun"
        "/var/lib/openclaw/qmd-cache:/home/node/.cache/qmd"
        "/var/lib/openclaw/dot-config:/home/node/.config"
      ];
      environment = {
        HOME = "/home/node";
        TERM = "xterm-256color";
        BROWSER = "echo";
        NPM_CONFIG_PREFIX = "/home/node/.npm-global";
        PATH = "/home/node/.bun/bin:/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        PLAYWRIGHT_BROWSERS_PATH = "/home/node/.cache/ms-playwright";
      };
      environmentFiles = [ "/run/openclaw.env" ];
      cmd = [
        "node"
        "dist/index.js"
      ];
      extraOptions = [
        "--init"
        "--tty"
        "--interactive"
        "--user=${toString config.users.users.openclaw.uid}:${toString config.users.groups.openclaw.gid}"
      ];
      autoStart = false;
    };
  };

  # ===================
  # Data directories
  # ===================
  systemd.tmpfiles.rules = [
    "d /var/lib/openclaw 0755 openclaw openclaw -"
    "d /var/lib/openclaw/config 0755 openclaw openclaw -"
    "d /var/lib/openclaw/workspace 0755 openclaw openclaw -"
    "d /var/lib/openclaw/npm-cache 0755 openclaw openclaw -"
    "d /var/lib/openclaw/npm-global 0755 openclaw openclaw -"
    "d /var/lib/openclaw/browsers 0755 openclaw openclaw -"
    "d /var/lib/openclaw/bun 0755 openclaw openclaw -"
    "d /var/lib/openclaw/qmd-cache 0755 openclaw openclaw -"
  ];

  # ===================
  # Firewall
  # ===================
  networking.firewall.allowedTCPPorts = [
    gatewayPort
    bridgePort
  ];
  networking.firewall.allowedUDPPorts = [
    5353
  ];
}
