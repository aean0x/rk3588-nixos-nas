# Hermes Agent (NousResearch/hermes-agent) — container mode
# Persistent Ubuntu 24.04 container; agent can apt/pip/npm install at runtime.
# Nix store bind-mounted ro; /var/lib/hermes → /data rw; CLI routes into container transparently.
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

  # Stable Nix store path — activation script reads from here, not from the workspace copy.
  # docs: documents option only writes to workingDirectory (workspace); it does NOT set
  # the primary identity at HERMES_HOME/.hermes/SOUL.md. Must install directly.
  soulMd = pkgs.writeText "hermes-soul.md" (builtins.readFile ./workspace/soul.md);
in
{
  imports = [
    inputs.hermes-agent.nixosModules.default
    ./onedrive.nix
    ./dashboard.nix
  ];

  _module.args.hermes = hermes;

  # The dashboard service runs as hermes and needs docker exec access.
  # hermes is a system user; without docker group it cannot run docker exec for CLI routing.
  users.users.hermes.extraGroups = [ "docker" ];

  services.hermes-agent = {
    enable = true;

    container = {
      enable = true;
      backend = "docker";
      image = "ubuntu:24.04";
      hostUsers = [ settings.adminUser ];
      # Port mapping so the dashboard (bound to 0.0.0.0:9119 inside the container)
      # is reachable at host 127.0.0.1:9119 for Caddy to proxy.
      extraOptions = [
        "-p" "127.0.0.1:9119:9119"
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
    ];

    settings = {
      model = {
        provider = "xai";
        default = "grok-4.3";
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

    # web: FastAPI + Uvicorn for the dashboard HTTP server.
    # pty: ptyprocess for the in-browser Chat tab (PTY/WebSocket bridge).
    # telegram: python-telegram-bot gateway adapter.
    extraDependencyGroups = [ "web" "pty" "telegram" ];

    restart = "always";
    restartSec = 5;
  };

  # Module creates ${stateDir}/workspace; only the onedrive subdir needs explicit setup.
  systemd.tmpfiles.rules = [
    "d ${hermes.workspace}/onedrive 2770 hermes hermes - -"
  ];

  # Install SOUL.md from the Nix store into HERMES_HOME — the primary identity path.
  # Runs after hermes-agent-setup (module activation) so the .hermes dir already exists.
  system.activationScripts.hermes-soul = lib.stringAfter [ "hermes-agent-setup" ] ''
    mkdir -p "${hermes.stateDir}/.hermes"
    install -o hermes -g hermes -m 0640 ${soulMd} "${hermes.stateDir}/.hermes/SOUL.md"
  '';
}
