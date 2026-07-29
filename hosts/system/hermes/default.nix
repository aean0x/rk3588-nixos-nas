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
    ./package-fix.nix # hermes_state_* modules missing from 0.19.0 wheel
    ./toolbox.nix # everyday CLI toolkit → /data/toolbox/bin + agent PATH
    ./onedrive.nix
    ./dashboard.nix
    ./gbrain.nix
    ./workstation.nix
    ./browser.nix # persistent Brave + loopback CDP for agent automation
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
        # Primary: xAI OAuth (run `hermes auth add xai-oauth` once after deploy).
        provider = "xai-oauth";
        default = "grok-4.5";
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

      # Tighter context compression; aux model routes below (not main xai-oauth).
      compression = {
        enabled = true;
        threshold = 0.55;
        target_ratio = 0.18;
        protect_last_n = 15;
      };

      # ── Model routing (explicit axes — Hermes has no smart task classifier) ──
      # Primary chat/orchestration stays on grok-4.5 (model.* above).
      # Routine / uncreative work is pinned to OpenRouter DeepSeek Flash:
      #   - delegation.*  → child agents from the `delegate` tool only
      #   - auxiliary.*   → side LLM (compress, titles, approvals, monitors…)
      #   - cron.model*   → unpinned scheduled jobs (fleet default; beats chat model)
      # Per-job pins (jobs.json model/provider) still win over cron.model.
      # Interactive Telegram/chat never uses cron/delegation models unless
      # the parent deliberately delegates.

      # Sub-agent traffic (parent still orchestrates on main model).
      delegation = {
        model = "deepseek/deepseek-v4-flash";
        provider = "openrouter";
      };

      # Aux LLM tasks — "auto" would fall back to main grok spend.
      auxiliary = {
        compression = {
          model = "deepseek/deepseek-v4-flash";
          provider = "openrouter";
        };
        title_generation = {
          model = "deepseek/deepseek-v4-flash";
          provider = "openrouter";
        };
        approval = {
          model = "deepseek/deepseek-v4-flash";
          provider = "openrouter";
        };
        # High-volume / mechanical side work that would otherwise inherit main.
        skills_hub = {
          model = "deepseek/deepseek-v4-flash";
          provider = "openrouter";
        };
        monitor = {
          model = "deepseek/deepseek-v4-flash";
          provider = "openrouter";
        };
        background_review = {
          model = "deepseek/deepseek-v4-flash";
          provider = "openrouter";
        };
        memory_query_rewrite = {
          model = "deepseek/deepseek-v4-flash";
          provider = "openrouter";
        };
      };

      # Cron fleet default: unpinned jobs (project-heartbeat, daylight-checks, …)
      # must NOT inherit model.default=grok-4.5. Resolution at fire:
      #   job.model > cron.model > HERMES_MODEL > model.default
      # Setting these also skips the model_drift_guard for that axis.
      cron = {
        model = "deepseek/deepseek-v4-flash";
        model_provider = "openrouter";
        model_drift_guard = true;
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

      # Skills / plugins dirs on the hermes volume (see toolbox activation).
      skills.external_dirs = [
        "/data/skills"
        "/var/lib/hermes/skills"
      ];
      # User plugins also live under ~/.hermes/plugins (gbrain-reflex activation).
      # `enabled` is the first-party opt-in allow-list (hermes_cli plugins).
      plugins = {
        external_dirs = [ "/var/lib/hermes/plugins" ];
        enabled = [ "gbrain-reflex" ];
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
    extraDependencyGroups = [
      "messaging"
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
