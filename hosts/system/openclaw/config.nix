# OpenClaw gateway configuration - generated as JSON via builtins.toJSON
# Secret placeholders (${VAR}) are resolved by OpenClaw at runtime from process env.
# Nix-evaluable values (domain, port) are inlined at build time.
# Agent definitions imported from agents.nix - single source of truth.
# Runtime mutable: setup copies this to /var/lib/openclaw/openclaw.json (writable).
{
  pkgs,
  lib,
  settings,
  oc,
  ...
}:
let
  agentDefs = import ./agents.nix { inherit oc; };
  gatewayUrl = "ws://172.17.0.1:${toString oc.port}";

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
          cdpUrl = "https://production-sfo.browserless.io?token=${oc.env "BROWSERLESS_API_TOKEN"}";
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
        apiKey = oc.env "XAI_API_KEY";
        api = "openai-responses";
        models = [
          {
            id = "grok-4.20-beta";
            name = "Grok 4.20 Beta";
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

    agents =
      lib.recursiveUpdate
        (builtins.removeAttrs (agentDefs.mkAgentsConfig {
          inherit gatewayUrl;
        }) [ "tools" ])
        {
          defaults = {
            sandbox.browser = {
              enabled = true;
              allowHostControl = false;
              image = "openclaw-sandbox-browser:bookworm-slim";
            };
            model = {
              primary = "xai/grok-4.20-beta";
              fallbacks = [
                "xai/grok-4-1-fast-reasoning"
                "xai/grok-4-1-fast-non-reasoning"
              ];
            };
            models = {
              "xai/grok-4.20-beta".alias = "grok-4.20-beta";
              "xai/grok-4-1-fast-reasoning".alias = "grok-reasoning";
              "xai/grok-4-1-fast-non-reasoning".alias = "grok-non-reasoning";
            };
            thinkingDefault = "medium";
            workspace = oc.containerWorkspace;
            memorySearch = {
              enabled = true;
              provider = "gemini";
              remote.apiKey = oc.env "GEMINI_API_KEY";
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
          };
        };

    tools = lib.recursiveUpdate (agentDefs.mkAgentsConfig { inherit gatewayUrl; }).tools {
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
          telegram = [ (oc.env "TELEGRAM_ADMIN_ID") ];
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
      groupAllowFrom = [ (oc.env "TELEGRAM_ADMIN_ID") ];
      streaming = "block";
    };

    gateway = {
      port = oc.port;
      mode = "local";
      bind = "loopback";
      controlUi = {
        enabled = true;
        allowedOrigins = [ "https://openclaw.${settings.domain}" ];
      };
      auth = {
        mode = "token";
        token = oc.env "OPENCLAW_GATEWAY_TOKEN";
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
      "${oc.containerEnv.OPENCLAW_STATE_DIR}/skills"
      "${oc.containerWorkspace}/skills"
    ];

    plugins.entries.telegram.enabled = true;
  };
in
{
  inherit agentDefs;
  configFile = pkgs.writeText "openclaw.json" (builtins.toJSON config);
}
