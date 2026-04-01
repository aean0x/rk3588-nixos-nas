# OpenClaw gateway configuration - generated as JSON via builtins.toJSON
# Secret placeholders (${VAR}) are resolved by OpenClaw at runtime from process env.
# Nix-evaluable values (domain, port) are inlined at build time.
# Agent definitions imported from agents.nix - single source of truth.
# Runtime mutable: setup copies this to /var/lib/openclaw/openclaw.json (writable).
{
  pkgs,
  lib,
  settings,
  openclaw-agents,
  ...
}:
let
  agentDefs = import ./agents.nix { inherit pkgs lib openclaw-agents; };
  port = 18789;
  gatewayUrl = "ws://172.17.0.1:${toString port}";
  workspace = "/home/node/.openclaw/workspace";

  # Host-side paths — Docker daemon resolves sandbox bind sources against the HOST filesystem
  hostWorkspace = "/var/lib/openclaw/workspace";

  # Produces literal ${VAR} in output JSON - OpenClaw resolves from process env
  env = name: "\${${name}}";

  # Common sandbox env shared by all sub-agents
  sandboxEnv = {
    HOME = "/home/node";
    OPENCLAW_HOME = "/home/node";
    OPENCLAW_STATE_DIR = "/home/node/.openclaw";
    OPENCLAW_CONFIG_PATH = "/home/node/.openclaw/openclaw.json";
    OPENCLAW_GATEWAY_TOKEN = env "OPENCLAW_GATEWAY_TOKEN";
    OPENCLAW_GATEWAY_URL = gatewayUrl;
    BRAVE_API_KEY = env "BRAVE_API_KEY";
    GOOGLE_PLACES_API_KEY = env "GOOGLE_PLACES_API_KEY";
    BROWSERLESS_API_TOKEN = env "BROWSERLESS_API_TOKEN";
  };

  config = {
    logging.redactSensitive = "tools";

    browser = {
      enabled = true;
      headless = true;
      defaultProfile = "local";
      executablePath = "/run/current-system/sw/bin/chromium";
      noSandbox = true;
      profiles = {
        local = {
          cdpPort = 18800;
          color = "#00AA00";
        };
        remote = {
          cdpUrl = "https://production-sfo.browserless.io?token=${env "BROWSERLESS_API_TOKEN"}";
          color = "#FF9900";
        };
      };
    };

    auth.profiles."xai:default" = {
      provider = "xai";
      mode = "api_key";
    };

    models = {
      mode = "merge";
      providers.xai = {
        baseUrl = "https://api.x.ai/v1";
        apiKey = env "XAI_API_KEY";
        api = "openai-responses";
        models = [
          {
            id = "grok-4.20";
            name = "Grok 4.20";
          }
          {
            id = "grok-4-1-fast-non-reasoning";
            name = "Grok 4.1 Fast";
          }
          {
            id = "grok-4-1-fast-reasoning";
            name = "Grok 4.1 Fast Reasoning";
          }
        ];
      };
    };

    agents = {
      defaults = {
        model = {
          primary = "xai/grok-4.20-beta";
          fallbacks = [
            "xai/grok-4-1-fast-reasoning"
            "xai/grok-4-1-fast-non-reasoning"
          ];
        };
        models = {
          "xai/grok-4.20-beta".alias = "grok-beta";
          "xai/grok-4-1-fast-reasoning".alias = "grok-reasoning";
          "xai/grok-4-1-fast-non-reasoning".alias = "grok-non-reasoning";
        };
        inherit workspace;
        memorySearch = {
          enabled = true;
          provider = "gemini";
          remote.apiKey = env "GEMINI_API_KEY";
          model = "gemini-embedding-001";
        };
        contextPruning = {
          mode = "cache-ttl";
          ttl = "12h";
          keepLastAssistants = 3;
          softTrimRatio = 0.3;
          hardClearRatio = 0.5;
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
          model = "xai/grok-4-1-fast-reasoning";
          every = "30m";
        };
        subagents.model = "xai/grok-4-1-fast-reasoning";
        sandbox = {
          mode = "non-main";
          workspaceAccess = "none";
          scope = "agent";
          docker = {
            image = "openclaw-sandbox-custom:latest";
            readOnlyRoot = true;
            tmpfs = [
              "/tmp"
              "/run"
              "/var/tmp"
              "/dev/shm"
            ];
            network = "bridge";
            user = "1000:1000";
            capDrop = [ "ALL" ];
            dangerouslyAllowExternalBindSources = true;
            env = sandboxEnv;
            cpus = 1;
            binds = [
              "${hostWorkspace}/skills:/skills:ro"
              "${hostWorkspace}/dropbox:/dropbox:rw"
            ];
          };
          browser = {
            enabled = true;
            allowHostControl = false;
            image = "openclaw-sandbox-browser:bookworm-slim";
          };
        };
      };

      list = agentDefs.mkJsonConfig { inherit workspace gatewayUrl; };
    };

    tools = {
      # Global profile — registers base tool set for all agents (subs inherit this)
      profile = "full";

      web = {
        search = {
          enabled = true;
          provider = "grok";
          maxResults = 8;
        };
        fetch = {
          enabled = true;
          maxChars = 50000;
        };
      };
      elevated = {
        enabled = true;
        allowFrom = {
          main = [ "*" ];
          telegram = [ (env "TELEGRAM_ADMIN_ID") ];
        };
      };
      exec = {
        security = "full";
        ask = "off";
        applyPatch.enabled = true;
      };
      media = {
        audio = {
          enabled = true;
          models = [
            {
              type = "cli";
              command = "whisper";
              args = [
                "--model"
                "base"
                "{{MediaPath}}"
              ];
              timeoutSeconds = 45;
            }
          ];
        };
      };
      alsoAllow = [
        "lobster"
      ];

      # Sandbox tool filter (layer 7).
      # Wildcards don't work here — must use explicit group names.
      # This is a separate gate from tools.profile; both must permit a tool.
      sandbox.tools = {
        allow = [
          "group:fs"
          "group:runtime"
          "group:sessions"
          "group:web"
          "group:memory"
          "group:ui"
          "group:openclaw"
          "lobster"
          "image"
        ];
        deny = [ ];
      };
    };

    messages = {
      ackReactionScope = "group-mentions";
      tts = {
        auto = "inbound";
        provider = "edge";
      };
    };

    commands = {
      native = "auto";
      nativeSkills = "auto";
      text = true;
      bash = false;
      config = true;
      restart = true;
      ownerDisplay = "raw";
    };

    hooks.internal = {
      enabled = true;
      entries = {
        boot-md.enabled = true;
        bootstrap-extra-files.enabled = true;
      };
    };

    channels.telegram = {
      enabled = true;
      dmPolicy = "pairing";
      groupPolicy = "allowlist";
      groupAllowFrom = [ (env "TELEGRAM_ADMIN_ID") ];
      streaming = true;
    };

    gateway = {
      inherit port;
      mode = "local";
      bind = "loopback";
      controlUi = {
        enabled = true;
        allowedOrigins = [ "https://openclaw.${settings.domain}" ];
      };
      auth = {
        mode = "token";
        token = env "OPENCLAW_GATEWAY_TOKEN";
        allowTailscale = true;
      };
      trustedProxies = [
        "127.0.0.1"
        "::1"
      ];
      tailscale = {
        mode = "off";
        resetOnExit = false;
      };
    };

    skills.install.nodeManager = "npm";

    skills.load.extraDirs = [
      "/home/node/.openclaw/skills"
      "/home/node/.openclaw/workspace/skills"
    ];

    plugins.entries.telegram.enabled = true;
  };
in
{
  inherit port agentDefs;
  configFile = pkgs.writeText "openclaw.json" (builtins.toJSON config);
}
