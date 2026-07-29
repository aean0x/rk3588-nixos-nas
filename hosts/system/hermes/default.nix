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
    ./onedrive.nix
    ./dashboard.nix
    ./gbrain.nix
    ./workstation.nix
    ./browser.nix # persistent Chromium + loopback CDP for agent automation
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
      "/run/hermes-browser.env" # BU_CDP_URL from ./browser.nix (loopback Chromium)
    ];

    settings = {
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

      compression = {
        enabled = true;
        threshold = 0.8;
      };

      security = {
        allow_lazy_installs = false;
        allow_private_urls = true;
        redact_secrets = true;
      };

      approvals.timeout = 120;

      # Match host timezone so cron schedules and session timestamps are correct.
      timezone = "Europe/Berlin";

      max_turns = 120;
      agent.max_turns = 80;
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
  # The alias is transparent for interactive use; SETENV preserves HERMES_HOME and terminal state.
  security.sudo.extraRules = [
    {
      users = [ settings.adminUser ];
      runAs = "hermes";
      commands = [
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

  environment.shellAliases.hermes = "sudo -u hermes /run/current-system/sw/bin/hermes";

  # SOUL.md declarative install is intentionally disabled.
  # Leave identity blank for a fresh agent; optional local draft: workspace/soul.md (not applied).
  # system.activationScripts.hermes-soul — removed.

}
