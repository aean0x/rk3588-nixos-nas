# Hermes Agent (NousResearch/hermes-agent) — container mode
# Persistent Ubuntu 24.04 container; agent can apt/pip/npm install at runtime.
# Nix store bind-mounted ro; /var/lib/hermes → /data rw; CLI routes into container transparently.
#
# Identity (SOUL.md): intentionally NOT declaratively installed — fresh agent owns its persona.
# Long-term memory: G-Brain via ./gbrain.nix (see ./memory/AGENTS.md + ./BOOTSTRAP.md).
{
  lib,
  pkgs,
  settings,
  inputs,
  ...
}:
let
  hermes = {
    stateDir = "/var/lib/hermes";
    workspace = "/var/lib/hermes/workspace";
  };
in
{
  imports = [
    inputs.hermes-agent.nixosModules.default
    ./package-fix.nix # silence marker fix (state modules OK in 0.19.1)
    ./toolbox.nix # everyday CLI toolkit → /data/toolbox/bin + agent PATH
    ./onedrive.nix
    ./dashboard.nix
    ./gbrain.nix
    ./workstation.nix
    ./browser.nix # persistent Brave + loopback CDP for agent automation
    ./hermes-webui.nix # Hermes WebUI (archimedes.<domain>) + ElevenLabs TTS
    ./context-manager.nix # hermes-context-manager (HMC) plugin pin + config
  ];

  _module.args.hermes = hermes;

  # Dashboard runs as hermes (owns .env); hermes needs docker group for docker exec routing.
  users.users.hermes.extraGroups = [ "docker" ];

  # adminUser needs hermes group membership so os.stat() can traverse .hermes/ (drwxrws---).
  users.users.${settings.adminUser}.extraGroups = [ "hermes" ];

  services.hermes-agent = {
    enable = true;

    container = {
      enable = true;
      backend = "docker";
      image = "ubuntu:24.04";
      hostUsers = [ settings.adminUser ];
      # Module always creates the container with --network=host (official module
      # hardcodes it). Publish flags (-p) are ignored under host networking;
      # dashboard binds 0.0.0.0:9119 on the host namespace directly. Only resource
      # limits belong in extraOptions here.
      extraOptions = [
        "--memory=4g"
        "--cpus=2"
      ];
    };

    # Puts `hermes` on system PATH and sets HERMES_HOME system-wide so interactive
    # CLI sessions share state (sessions, skills, cron) with the gateway service.
    addToSystemPackages = true;

    # Merged into ${stateDir}/.hermes/.env at activation. Re-read on every startup,
    # so secret rotation only needs `systemctl restart hermes-agent`.
    environmentFiles = [
      "/run/hermes.env"
      "/run/hermes-browser.env" # BROWSER_CDP_URL + noVNC URL (no password)
    ];

    settings = {
      # Attach browser_* tools to host Chromium CDP (see browser.nix).
      # browser_tool.py reads browser.cdp_url or env BROWSER_CDP_URL.
      browser = {
        cdp_url = "http://127.0.0.1:9222";
      };

      model = {
        # Token-default primary: DeepSeek Flash (OpenRouter).
        # Grok is escalation-only — money/RH, hard architecture, user `/model grok`.
        # Keep xAI OAuth configured (`hermes auth add xai-oauth`) for those pins.
        provider = "openrouter";
        default = "deepseek/deepseek-v4-flash";
        aliases = {
          ds = "openrouter/deepseek/deepseek-v4-flash";
          grok = "xai-oauth/grok-4.5";
        };
      };

      stt = {
        provider = "openai";
        model = "whisper-1";
      };

      toolsets = [ "all" ];

      terminal = {
        backend = "local";
        timeout = 300;
        cwd = "."; # relative to workingDirectory (/data/workspace in container)
      };

      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };

      # Token lean 80/20: native tool-output caps (0.19 DEFAULT_CONFIG knobs).
      # Skipped (not in 0.19 DEFAULT_CONFIG): tools.compact_schemas, skills.prompt_mode.
      tool_output = {
        max_bytes = 8000;
        max_lines = 200;
        max_line_length = 2000;
      };

      # Keep interactive under ~120k even on large-context models (grok 500k).
      # threshold_tokens is the absolute floor; percent alone never fires before 200k
      # because small-context floor raises the ratio trigger near 75% of 500k.
      compression = {
        enabled = true;
        threshold = 0.30;
        threshold_tokens = 120000;
        target_ratio = 0.18;
        protect_last_n = 8;
        proactive_prune_tokens = 24000;
        proactive_prune_min_result_chars = 2000;
        proactive_prune_min_reclaim_tokens = 2048;
        idle_compact_after_seconds = 1800;
      };

      # ── Model routing (token-default DS; Grok = escalate) ──
      # Primary chat = DeepSeek Flash (OpenRouter). Grok is NOT fleet default.
      # Cheap axes stay DeepSeek even if session is `/model grok`:
      #   delegation / auxiliary volume slots / unpinned cron
      # Escalate to Grok: money/RH job pins, hard architecture, user `/model grok`.
      # Vision: pin Grok (native vision) — do not inherit DS primary.
      # Docs: https://hermes-agent.nousresearch.com/docs/user-guide/configuring-models
      # `provider: auto` would inherit main for unset aux — every volume task pinned.

      # Sub-agent fleet (delegate_task). Parent stays on session main model.
      # Per-task overrides on delegate_task still escalate individual children.
      delegation = {
        model = "deepseek/deepseek-v4-flash";
        provider = "openrouter";
      };

      # Auxiliary slots (DEFAULT_CONFIG keys). reasoning_effort=none: Flash
      # tasks are structured/low-stakes and do not benefit from CoT spend.
      auxiliary =
        let
          flash = {
            model = "deepseek/deepseek-v4-flash";
            provider = "openrouter";
            reasoning_effort = "none";
          };
        in
        {
          # Almost always — session titles; default docs recommend flash.
          title_generation = flash;
          # Largest background token hitter on long sessions.
          compression = flash;
          # Smart approval classifier — haiku/flash class is enough.
          approval = flash;
          # Pure summarization; no reasoning required.
          web_extract = flash;
          # Skill search / matching.
          skills_hub = flash;
          # MCP helper / tool routing.
          mcp = flash;
          # Kanban triage expansion + decomposition graph.
          triage_specifier = flash;
          kanban_decomposer = flash;
          # Short profile blurbs.
          profile_describer = flash;
          # Skill-usage review (can run minutes on reasoning models).
          curator = flash;
          # Post-turn self-improvement fork (memory/skill capture).
          background_review = flash;
          # Monitor catalog urgency scoring (high volume).
          monitor = flash;
          # memory_query_rewrite already cheap; keep on fleet.
          memory_query_rewrite = flash;
          # Vision on Grok (native). Must pin — primary is now DeepSeek.
          vision = {
            model = "grok-4.5";
            provider = "xai-oauth";
          };
        };

      # Cron fleet default: unpinned jobs stay DeepSeek even if operator
      # temporarily sets model.default back to Grok.
      # Resolution at fire: job.model > cron.model > HERMES_MODEL > model.default
      cron = {
        model = "deepseek/deepseek-v4-flash";
        model_provider = "openrouter";
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

      # Skills / plugins dirs on the hermes volume (see toolbox + gbrain activation).
      skills.external_dirs = [
        "/data/skills"
        "/var/lib/hermes/skills"
      ];
      # 0.19 opt-in allow-list for user plugins (HMC + gbrain-reflex + thrash heal).
      # Discovery uses $HERMES_HOME/plugins; external_dirs also scanned.
      plugins = {
        external_dirs = [
          "/data/plugins"
          "/var/lib/hermes/plugins"
        ];
        enabled = [
          "hermes-context-manager"
          "gbrain-reflex"
          "gbrain-memory-flush"
          "tool-call-coherency"
          "projects-auto-commit"
        ];
      };

      # Match host timezone so cron schedules and session timestamps are correct.
      timezone = "Europe/Berlin";

      max_turns = 120;
      agent = {
        max_turns = 80;
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

    mcpServers = {
      maton = {
        command = "npx";
        args = [
          "-y"
          "@maton/mcp"
        ];
      };
      # gbrain MCP is declared in ./gbrain.nix (mcpServers.gbrain).
    };

    # Optional pyproject extras beyond the sealed default `[all]` set.
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
      users = [ settings.adminUser ];
      runAs = "hermes";
      commands = [
        {
          command = "/var/lib/hermes/bin/hermes-cli";
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

  # Toolbox PATH for host hermes chat/doctor (see toolbox.nix hermes-cli wrapper).
  environment.shellAliases.hermes = "sudo -u hermes /var/lib/hermes/bin/hermes-cli";

  # SOUL.md declarative install is intentionally disabled.
  # Leave identity blank for a fresh agent; optional local draft: workspace/soul.md (not applied).
  # system.activationScripts.hermes-soul — removed.

}
