# Hermes ↔ G-Brain: registry, MCP serve, simple host timers.
#
# Supported model (gbrain INSTALL_FOR_AGENTS + Hermes MCP):
#   - Agent installs gbrain (`bun install -g`) and uses MCP serve for read/write.
#   - Host jobs STOP hermes-agent (releases PGLite), run CLI as hermes, START again.
#   - No exclusive-cli / docker-exec race scaffolding.
{
  lib,
  pkgs,
  ...
}:

let
  memoryDir = ./memory;
  registryFile = "${memoryDir}/registry.json";
  schemaFile = "${memoryDir}/export-schema.json";
  agentsManifest = "${memoryDir}/AGENTS.md";

  runtime = with pkgs; [
    bash
    coreutils
    gnugrep
    gawk
    jq
    python3
    util-linux
    systemd
  ];

  consolidateScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-consolidate";
    runtimeInputs = runtime;
    # trap cleanup() looks unused to shellcheck
    excludeShellChecks = [
      "SC2329"
      "SC2181"
    ];
    text = builtins.readFile ./scripts/hermes-gbrain-consolidate.sh;
  };

  embedScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-embed";
    runtimeInputs = runtime;
    excludeShellChecks = [
      "SC2329"
      "SC2181"
    ];
    text = builtins.readFile ./scripts/hermes-gbrain-embed.sh;
  };

  dreamScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-dream";
    runtimeInputs = runtime;
    excludeShellChecks = [
      "SC2329"
      "SC2181"
    ];
    text = ''
      set -euo pipefail
      HOME_DIR=/var/lib/hermes/home
      export HOME="$HOME_DIR"
      export PATH="$HOME_DIR/.bun/bin:$HOME_DIR/.npm-global/bin:/var/lib/hermes/toolbox/bin:$PATH"
      started=0
      cleanup() {
        if [ "$started" -eq 1 ]; then
          systemctl start hermes-agent.service 2>/dev/null || true
        fi
      }
      trap cleanup EXIT
      systemctl stop hermes-agent.service
      started=1
      sleep 2
      rm -rf "$HOME_DIR/.gbrain/brain.pglite/.gbrain-lock" 2>/dev/null || true
      runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" gbrain dream
    '';
  };
in
{
  services.hermes-agent = {
    # Absolute path: hermes MCP filters PATH and bare `gbrain` often FileNotFoundError.
    # Agent install lands CLI at ~/.local/bin and/or ~/.bun/bin under hermes HOME.
    mcpServers.gbrain = {
      command = "/home/hermes/.local/bin/gbrain";
      args = [ "serve" ];
      connect_timeout = 120;
      timeout = 120;
      env = {
        HOME = "/home/hermes";
        PATH = "/home/hermes/.local/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/usr/local/bin:/usr/bin:/bin";
      };
    };

    environment = {
      HERMES_MEMORY_REGISTRY = "/data/memory/registry.json";
      GBRAIN_AUDIT_DIR = "/home/hermes/.gbrain/audit";
    };
  };

  systemd.services.hermes-gbrain-consolidate = {
    description = "Hermes memory snapshot + G-Brain inbox import (host CLI, hermes stopped)";
    after = [ "hermes-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${lib.getExe consolidateScript}";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.timers.hermes-gbrain-consolidate = {
    description = "Daily Hermes → G-Brain consolidation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "45min";
      Persistent = true;
    };
  };

  systemd.services.gbrain-dream = {
    description = "G-Brain overnight dream (host CLI, hermes stopped)";
    after = [ "hermes-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${lib.getExe dreamScript}";
    };
  };

  systemd.timers.gbrain-dream = {
    description = "G-Brain dream timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:30";
      Persistent = true;
    };
  };

  systemd.services.gbrain-embed = {
    description = "G-Brain embed --stale (host CLI, hermes stopped)";
    after = [ "hermes-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${lib.getExe embedScript}";
    };
  };

  systemd.timers.gbrain-embed = {
    description = "G-Brain embed timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 05:00";
      Persistent = true;
    };
  };

  environment.systemPackages = [
    consolidateScript
    embedScript
    dreamScript
  ];

  system.activationScripts.hermes-memory-manifest = lib.stringAfter [ "hermes-agent-setup" ] ''
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/memory
    install -m 0644 ${registryFile} /var/lib/hermes/memory/registry.json
    install -m 0644 ${schemaFile} /var/lib/hermes/memory/export-schema.json
    install -m 0644 ${agentsManifest} /var/lib/hermes/memory/AGENTS.md

    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/inbox
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/snapshots
    chown -R hermes:hermes /var/lib/hermes/.hermes/memories/export

    install -m 0640 -o hermes -g hermes ${agentsManifest} /var/lib/hermes/.hermes/AGENTS.md

    if [ ! -f /var/lib/hermes/.hermes/memories/MEMORY.md ]; then
      {
        echo '# MEMORY.md — working / short-horizon only'
        echo
        echo 'Durable knowledge → GBrain MCP put_page (see workspace/GBRAIN.md).'
      } > /var/lib/hermes/.hermes/memories/MEMORY.md
      chown hermes:hermes /var/lib/hermes/.hermes/memories/MEMORY.md
      chmod 0640 /var/lib/hermes/.hermes/memories/MEMORY.md
    fi

    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/workspace
    install -m 0640 -o hermes -g hermes ${./workspace/GBRAIN.md} /var/lib/hermes/workspace/GBRAIN.md

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain/audit
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/brain
  '';
}
