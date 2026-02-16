# OpenClaw (native, non-Docker)
{
  config,
  pkgs,
  ...
}:
let
  gatewayPort = 18789;
  bridgePort = 18790;

  # User home dir; OpenClaw naturally uses ~/.openclaw/ for state
  openclawHome = "/home/openclaw";
  openclawDataDir = "${openclawHome}/.openclaw";

  # Symlink for discoverability
  symlinkPath = "/var/lib/openclaw";

  # ===========================================================================
  # OpenClaw configuration — derived from the Docker module, adjusted for native.
  # Secrets (tokens, passwords, API keys) are injected via env vars from SOPS.
  # https://docs.openclaw.ai/gateway/configuration
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
        "172.17.0.1" # Docker bridge gateway (kept for compatibility)
      ];
      tailscale = {
        mode = "off"; # Tailscale runs natively on host
      };
    };

    # -- Browser ---------------------------------------------------------------
    browser = {
      executablePath = "${pkgs.chromium}/bin/chromium";
      headless = true;
      noSandbox = true;
    };

    # -- Agent defaults --------------------------------------------------------
    agents = {
      defaults = {
        model = {
          primary = "openrouter/x-ai/grok-4.1-fast";
          fallbacks = [
            "openrouter/google/gemini-3-flash-preview"
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
            params = {
              reasoning = {
                enabled = false; # Default non-reasoning for flash-like speed.
              };
            };
          };
          "openrouter/x-ai/grok-4.1-fast:medium" = {
            alias = "grok-medium";
            params = {
              reasoning = {
                enabled = true;
                effort = "medium"; # Balanced depth for sonnet-like restraint/multi-step.
              };
            };
          };
          "openrouter/x-ai/grok-4.1-fast:xhigh" = {
            alias = "grok-xhigh";
            params = {
              reasoning = {
                enabled = true;
                effort = "xhigh"; # Max critique layers for opus-like rigor.
              };
            };
          };
          "openrouter/openai/gpt-4.1-mini" = {
            alias = "gpt-mini";
          };
          "openrouter/openai/gpt-4.1-nano" = {
            alias = "gpt-nano";
          };
        };

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

    # -- Tools -----------------------------------------------------------------
    tools = {
      web = {
        search = {
          enabled = true;
        };
        fetch = {
          enabled = true;
        };
      };
    };

    # -- Channels --------------------------------------------------------------
    channels = {
      telegram = {
        enabled = true;
        dmPolicy = "pairing";
        groupPolicy = "allowlist";
        streamMode = "partial";
      };
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
      restart = true;
    };
  };

  configFile = pkgs.writeText "openclaw-desired.json" (builtins.toJSON openclawConfig);

  toolsPath = "${pkgs.openclaw-tools}/bin";

  # Wrapper runs CLI as the openclaw user — keeps perms tight.
  openclawCli = pkgs.writeShellScriptBin "oc" ''
    exec sudo -u openclaw ${pkgs.openclaw-gateway}/bin/openclaw "$@"
  '';
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
    uid = 1000;
    group = "openclaw";
    description = "OpenClaw service user";
    home = openclawHome;
    createHome = true;
    shell = pkgs.bash;
  };

  users.groups.openclaw = {
    gid = 1000;
  };

  # ===================
  # Packages
  # ===================
  environment.systemPackages = [
    pkgs.openclaw-gateway
    pkgs.openclaw-tools
    openclawCli
    pkgs.chromium
    pkgs.jq
    pkgs.curl
  ];

  # ===================
  # Symlink for discoverability
  # ===================
  systemd.tmpfiles.rules = [
    "d ${openclawDataDir} 0700 openclaw openclaw -"
    "L+ ${symlinkPath} - - - - ${openclawDataDir}"
  ];

  # ===================
  # Workspace cleanup (one-time)
  # ===================
  systemd.services.openclaw-workspace-cleanup = {
    description = "One-time cleanup of OpenClaw workspace (preserve onedrive and backups)";
    before = [ "openclaw-gateway.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    script = ''
      set -euo pipefail
      MARKER="${openclawDataDir}/.workspace_cleaned"
      if [ -f "$MARKER" ]; then
        exit 0
      fi

      WORKSPACE="${openclawDataDir}/workspace"
      mkdir -p "$WORKSPACE"
      chown openclaw:openclaw "$WORKSPACE"
      find "$WORKSPACE" -mindepth 1 -maxdepth 1 \
        ! -name "onedrive" \
        ! -name "backup*" \
        -exec rm -rf {} +

      touch "$MARKER"
      chown openclaw:openclaw "$MARKER"
      chmod 0600 "$MARKER"
    '';
  };

  # ===================
  # Secrets injector (root one-shot, lifecycle tied to gateway)
  # ===================
  systemd.services.openclaw-secrets = {
    description = "OpenClaw secrets injector";
    before = [ "openclaw-gateway.service" ];
    requiredBy = [ "openclaw-gateway.service" ];
    partOf = [ "openclaw-gateway.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      # Write Google Workspace MCP credentials from SOPS
      GWS_DIR="${openclawDataDir}/config/google-workspace-mcp"
      mkdir -p "$GWS_DIR"
      GWS_ID="$(cat ${config.sops.secrets.google_workspace_client_id.path})"
      GWS_SECRET="$(cat ${config.sops.secrets.google_workspace_client_secret.path})"
      printf '{"installed":{"client_id":"%s","project_id":"clawdbot-486907","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","auth_provider_x509_cert_url":"https://www.googleapis.com/oauth2/v1/certs","client_secret":"%s","redirect_uris":["http://localhost"]}}\n' \
        "$GWS_ID" "$GWS_SECRET" > "$GWS_DIR/credentials.json"
      chown openclaw:openclaw "$GWS_DIR" "$GWS_DIR/credentials.json"
      chmod 0700 "$GWS_DIR"
      chmod 0600 "$GWS_DIR/credentials.json"

      # Write API keys to environment file
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
      chmod 0640 /run/openclaw.env
      chown root:openclaw /run/openclaw.env
    '';
  };

  # ===================
  # OpenClaw user service
  # ===================
  systemd.user.services.openclaw-gateway = {
    description = "OpenClaw gateway";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "default.target" ];
    environment = {
      GOOGLE_DRIVE_OAUTH_CREDENTIALS = "${openclawDataDir}/config/google-workspace-mcp/credentials.json";
      GOOGLE_DRIVE_TOKENS = "${openclawDataDir}/config/google-workspace-mcp/tokens.json";
      PATH = "${toolsPath}:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:/run/current-system/sw/bin";
    };
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = openclawHome;
      EnvironmentFile = "/run/openclaw.env";
      ExecStartPre =
        let
          configDir = "${openclawDataDir}/config";
          configPath = "${configDir}/openclaw.json";
        in
        pkgs.writeShellScript "openclaw-config-merge" ''
          set -euo pipefail
          mkdir -p "${configDir}"
          CONF="${configPath}"
          if [ -f "$CONF" ]; then
            ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CONF" ${configFile} > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
          else
            cp ${configFile} "$CONF"
          fi
          chmod 0600 "$CONF"
        '';
      ExecStart = "${pkgs.openclaw-gateway}/bin/openclaw gateway --port ${toString gatewayPort}";
      Restart = "always";
      RestartSec = "2s";
    };
  };

  # Enable lingering so user service starts at boot without login
  users.users.openclaw.linger = true;

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
