# Hermes Agent (NousResearch/hermes-agent) — container mode
# Persistent Ubuntu 24.04 container; agent can apt/pip/npm install at runtime.
# Nix store bind-mounted ro; /var/lib/hermes → /data rw; CLI routes into container transparently.
#
# Identity (SOUL.md): intentionally NOT declaratively installed — fresh agent owns its persona.
# Long-term memory: G-Brain via ./gbrain.nix (see ./memory/AGENTS.md + ./BOOTSTRAP.md).
{
  config,
  lib,
  pkgs,
  settings,
  inputs,
  hermes,
  ...
}: {
  imports = [
    inputs.hermes-pnp.nixosModules.default
    ./runtime.nix # site identity + 2G agent resource SoT
    ./onedrive.nix
    ./gbrain.nix
    ./workstation.nix
    ./browser.nix # Brave engine override (CDP + noVNC come from the composer)
    ./hermes-webui.nix # public edge + remaps; composer pairs identity
    ./plugins.nix # HMC extraPlugin + host skills
    ./mcp.nix # composio MCP proxy
  ];

  services.hermesPnP = {
    enable = true;
    models = {
      low = {
        provider = "deepseek";
        model = "deepseek-v4-flash";
      };
      medium = {
        provider = "deepseek";
        model = "deepseek-v4-pro";
      };
      high = {
        provider = "xai-oauth";
        model = "grok-4.6";
      };
    };
    plugins = [
      "model-router"
      "tool-call-coherency"
      "secret-handoff"
      "projects-auto-commit"
    ];
  };

  # hermes CLI routes into the container via docker exec (hermes-cli wrapper).
  users.users.hermes.extraGroups = ["docker"];

  # adminUser needs hermes group membership so os.stat() can traverse .hermes/ (drwxrws---).
  users.users.${settings.adminUser}.extraGroups = ["hermes"];

  services.hermes-agent = {
    enable = true;

    container = {
      enable = true;
      backend = "docker";
      image = "ubuntu:24.04";
      hostUsers = [settings.adminUser];
      # Module always creates the container with --network=host (official module
      # hardcodes it). Publish flags (-p) are ignored under host networking.
      # Resource flags from runtime.nix (same numbers as WebUI systemd).
      extraOptions = hermes.containerResourceOptions;
    };

    # Puts `hermes` on system PATH and sets HERMES_HOME system-wide so interactive
    # CLI sessions share state (sessions, skills, cron) with the gateway service.
    addToSystemPackages = true;

    # Merged into ${stateDir}/.hermes/.env at activation. Re-read on every startup,
    # so secret rotation only needs `systemctl restart hermes-agent`.
    environmentFiles = [
      "/run/hermes.env"
      # /run/hermes-browser.env is added by services.hermesPnP.browser.
    ];

    settings = {
      # browser.cdp_url + BROWSER_CDP_URL come from services.hermesPnP.browser.

      # Session identity (provider/default/fallback) comes from
      # hermesPnP.models.high. Keep only keys the composer does not seed.
      model = {
        # SoT window: WebUI + compressor + HMC all honor this (runtime.nix).
        context_length = hermes.contextLimit;
      };

      stt = {
        provider = "openai";
        model = "whisper-1";
      };

      # Durable TTS SoT (HERMES_MANAGED) — not `hermes config set`.
      tts = {
        provider = "elevenlabs";
        elevenlabs = {
          voice_id = "DfE5EkknFF950NR6OMui";
          model_id = "eleven_flash_v2_5";
        };
      };

      toolsets = ["all"];

      terminal = {
        backend = "local";
        timeout = 300;
        cwd = "."; # relative to workingDirectory (/data/workspace in container)
      };

      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };

      # Token lean: native tool-output caps (DEFAULT_CONFIG knobs).
      # Keep dumps small so menial turns don't open near the HMC/native budget.
      # Skipped (not in DEFAULT_CONFIG): tools.compact_schemas, skills.prompt_mode.
      tool_output = {
        max_bytes = 6000;
        max_lines = 150;
        max_line_length = 2000;
      };

      # Native compact: blanket cap 180k. DeepSeek V4 (1M catalog window,
      # no 75% floor) fires at 0.18 × window ≈ 180k. Grok 4.6 on the 200k
      # pin is floored to 75% ≈ 150k. After a hop-back Grok may adopt the
      # 500k catalog window and then the 180k cap wins.
      compression = {
        enabled = true;
        threshold = hermes.compressionThreshold;
        threshold_tokens = hermes.compressionThresholdTokens;
        model_thresholds = {
          "deepseek-v4" = 0.18;
        };
        target_ratio = 0.15;
        protect_last_n = 8;
        proactive_prune_tokens = 24000;
        proactive_prune_min_result_chars = 2000;
        proactive_prune_min_reclaim_tokens = 2048;
        idle_compact_after_seconds = 1800;
      };

      # ── Model routing ──
      # Per-turn chat: hermes-pnp model-router (low / medium / high).
      # Session identity is high. Auxiliary + unpinned cron are low.
      # Delegation children are medium. Vision omitted → inherits high.
      # Docs: https://hermes-agent.nousresearch.com/docs/user-guide/configuring-models

      # Sub-agent fleet (delegate_task). Model/provider: hermesPnP.models.medium.
      # Leave the platform slot empty so they inherit the parent session and
      # skip final-voice polish (model-router).
      delegation = {
        max_concurrent_children = 5;
      };

      # Auxiliary + cron models: hermesPnP.models.low.
      cron = {
        model_drift_guard = true;
        # Mobile noty: raw agent text (no Cronjob Response header/footer).
        wrap_response = false;
      };

      # Lazy tool schema loading to cut MCP/tool definition tax; keep toolsets = [ "all" ].
      tools = {
        tool_search = {
          enabled = "auto";
        };
      };

      security = {
        allow_lazy_installs = false;
        allow_private_urls = true;
        redact_secrets = true;
      };

      approvals = {
        mode = "smart";
        timeout = 120;
        cron_mode = "deny";
      };

      # Skills dirs on the hermes volume (see toolbox + gbrain activation).
      # Plugins enabled list + install: ./plugins.nix (single source of truth).
      skills.external_dirs = [
        hermes.skills.container
        hermes.skills.host
      ];

      # Needs HERMES_BUNDLED_PLUGINS (composer package wrap)
      # so discovery finds share/…/plugins/web/*/plugin.yaml.
      web = {
        search_backend = "xai";
        extract_backend = "firecrawl";
      };

      # Match host timezone so cron schedules and session timestamps are correct.
      timezone = "Europe/Berlin";

      max_turns = 120;
      agent = {
        max_turns = 80;
        # Ride out brief local DNS blips (EAI_AGAIN) without killing the whole
        # cron tick. Default 3 was too tight when public resolv had no cache.
        api_max_retries = 8;
        # Safe platform toolset prune only (HA/cron/web/browser/etc. stay enabled).
        disabled_toolsets = [
          "video"
          "video_gen"
          "spotify"
          "yuanbao"
          "computer_use"
        ];
      };
    };

    # mcpServers: ./mcp.nix (composio via flake hermes-pnp) + gbrain.nix.

    # Optional pyproject extras beyond the sealed default `[all]` set.
    # Composer bakes these into services.hermes-agent.package
    # so WebUI passthru.hermesVenv matches the gateway (do not re-override).
    # - messaging: Telegram/Discord/Slack — removed from `[all]` (2026-05-12); required for gateway.
    # - firecrawl: web_extract / Firecrawl provider (firecrawl-py); lazy install disabled in Nix.
    extraDependencyGroups = [
      "messaging"
      "firecrawl"
    ];

    restart = "always";
    restartSec = 5;
  };

  # Module creates ${stateDir}/workspace; only the onedrive subdir needs explicit setup.
  systemd.tmpfiles.rules = [
    "d ${hermes.workspace}/onedrive 2770 hermes hermes - -"
  ];

  # hermes CLI runs as the hermes service user via sudo so it can read .env (0600 hermes:hermes).
  # Alias uses hermes-cli (toolbox PATH) like Hetzner; keep stock hermes for direct calls.
  security.sudo.extraRules = [
    {
      users = [settings.adminUser];
      runAs = "hermes";
      commands = [
        {
          command = "${config.services.hermesPnP.toolbox.binDir}/hermes-cli";
          options = [
            "NOPASSWD"
            "SETENV"
          ];
        }
        {
          command = "/run/current-system/sw/bin/hermes";
          options = [
            "NOPASSWD"
            "SETENV"
          ];
        }
      ];
    }
  ];

  # Toolbox PATH for host hermes chat/doctor (composer toolbox hermes-cli wrapper).
  environment.shellAliases.hermes = "sudo -u hermes ${config.services.hermesPnP.toolbox.binDir}/hermes-cli";

  # SOUL.md declarative install is intentionally disabled.
  # Leave identity blank for a fresh agent; optional local draft: workspace/soul.md (not applied).
  # system.activationScripts.hermes-soul — removed.
}
