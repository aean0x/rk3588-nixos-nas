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
      # gbrain config uses absolute /home/hermes paths (container); host needs symlink.
      if [ ! -e /home/hermes ]; then
        ln -sfn "$HOME_DIR" /home/hermes
      fi
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
      pkill -f 'gbrain serve' 2>/dev/null || true
      rm -rf "$HOME_DIR/.gbrain/brain.pglite/.gbrain-lock" 2>/dev/null || true
      runuser -u hermes -- env HOME="$HOME_DIR" PATH="$PATH" gbrain dream
    '';
  };

  # Legacy container-path helper under /var/lib/hermes/bin (bind-mounted as /data/bin).
  # Keep in sync with host consolidateScript: MEMORY→inbox dump is opt-in only.
  consolidateInnerScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-consolidate-inner";
    runtimeInputs = runtime;
    excludeShellChecks = [
      "SC2329"
      "SC2181"
      "SC2016" # intentional jq single-quoted filters
    ];
    text = builtins.readFile ./scripts/hermes-gbrain-consolidate-inner.sh;
  };
in
{
  services.hermes-agent = {
    # Match Hetzner: bare `gbrain`. Explicit PATH so MCP child resolution does not
    # depend on filtered/stale env (deep-merge used to keep a bad PATH with .local/bin).
    mcpServers.gbrain = {
      command = "gbrain";
      args = [ "serve" ];
      connect_timeout = 120;
      timeout = 120;
      env = lib.mkForce {
        HOME = "/home/hermes";
        PATH = "/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/usr/local/bin:/usr/bin:/bin";
      };
    };

    environment = {
      HERMES_MEMORY_REGISTRY = "/data/memory/registry.json";
      GBRAIN_AUDIT_DIR = "/home/hermes/.gbrain/audit";
      # Static alias index for gbrain-reflex pre_llm_call (container path).
      GBRAIN_POINTER_INDEX = "/data/workspace/gbrain-pointer-index.json";
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

  # Daily consolidate (MEMORY snapshot → gbrain put + dream + brain sync).
  # Also: gbrain-dream @ 04:30, gbrain-embed @ Sun 05:00. Manual:
  #   sudo hermes-gbrain-consolidate
  #   systemctl start hermes-gbrain-consolidate.service
  systemd.timers.hermes-gbrain-consolidate = {
    description = "Daily Hermes → G-Brain consolidation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "45min";
      Persistent = true;
      Unit = "hermes-gbrain-consolidate.service";
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
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    install -m 0755 -o root -g hermes ${lib.getExe consolidateInnerScript} \
      /var/lib/hermes/bin/hermes-gbrain-consolidate-inner

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
    install -m 0640 -o hermes -g hermes ${./workspace/gbrain-pointer-index.json} \
      /var/lib/hermes/workspace/gbrain-pointer-index.json

    # gbrain-reflex plugin (user plugins under HERMES_HOME/plugins + external_dirs).
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/.hermes/plugins/gbrain-reflex
    install -m 0644 -o hermes -g hermes ${./plugins/gbrain-reflex/plugin.yaml} \
      /var/lib/hermes/.hermes/plugins/gbrain-reflex/plugin.yaml
    install -m 0644 -o hermes -g hermes ${./plugins/gbrain-reflex/__init__.py} \
      /var/lib/hermes/.hermes/plugins/gbrain-reflex/__init__.py
    # gbrain-memory-flush: background_review → MCP put_page + MEMORY prune
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/.hermes/plugins/gbrain-memory-flush
    install -m 0644 -o hermes -g hermes ${./plugins/gbrain-memory-flush/plugin.yaml} \
      /var/lib/hermes/.hermes/plugins/gbrain-memory-flush/plugin.yaml
    install -m 0644 -o hermes -g hermes ${./plugins/gbrain-memory-flush/__init__.py} \
      /var/lib/hermes/.hermes/plugins/gbrain-memory-flush/__init__.py
    if [ -d /var/lib/hermes/plugins ]; then
      install -d -m 0755 -o hermes -g hermes /var/lib/hermes/plugins/gbrain-reflex
      install -m 0644 -o hermes -g hermes ${./plugins/gbrain-reflex/plugin.yaml} \
        /var/lib/hermes/plugins/gbrain-reflex/plugin.yaml
      install -m 0644 -o hermes -g hermes ${./plugins/gbrain-reflex/__init__.py} \
        /var/lib/hermes/plugins/gbrain-reflex/__init__.py
      install -d -m 0755 -o hermes -g hermes /var/lib/hermes/plugins/gbrain-memory-flush
      install -m 0644 -o hermes -g hermes ${./plugins/gbrain-memory-flush/plugin.yaml} \
        /var/lib/hermes/plugins/gbrain-memory-flush/plugin.yaml
      install -m 0644 -o hermes -g hermes ${./plugins/gbrain-memory-flush/__init__.py} \
        /var/lib/hermes/plugins/gbrain-memory-flush/__init__.py
    fi

    # retrieval-reflex policy skill (skills.external_dirs).
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/skills/retrieval-reflex
    install -m 0644 -o hermes -g hermes ${./skills/retrieval-reflex/SKILL.md} \
      /var/lib/hermes/skills/retrieval-reflex/SKILL.md

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain/audit
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/brain

    # Host CLI / timers: gbrain config stores database_path=/home/hermes/.gbrain/...
    # (set inside the container). Symlink so host paths resolve the same way.
    if [ ! -e /home/hermes ]; then
      ln -sfn /var/lib/hermes/home /home/hermes
    elif [ ! -L /home/hermes ] && [ ! -d /home/hermes ]; then
      ln -sfn /var/lib/hermes/home /home/hermes
    fi

    # Re-assert mcpServers.gbrain + plugins.enabled after hermes-agent-setup / agent edits.
    # Managed mode blocks agent writes, but deep-merge races can drop the blocks.
    cfg=/var/lib/hermes/.hermes/config.yaml
    if [ -f "$cfg" ]; then
      ${pkgs.python3}/bin/python3 - "$cfg" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit(0)
path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text()) or {}
changed = False

mcp = data.setdefault("mcp_servers", {})
desired_mcp = {
    "command": "gbrain",
    "args": ["serve"],
    "connect_timeout": 120,
    "timeout": 120,
    "enabled": True,
    "env": {
        "HOME": "/home/hermes",
        "PATH": "/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/usr/local/bin:/usr/bin:/bin",
    },
}
if mcp.get("gbrain") != desired_mcp:
    mcp["gbrain"] = desired_mcp
    changed = True

# Opt-in allow-list: gbrain-reflex + HMC + memory-flush.
plugins = data.setdefault("plugins", {})
if not isinstance(plugins, dict):
    plugins = {}
    data["plugins"] = plugins
enabled = plugins.get("enabled")
if not isinstance(enabled, list):
    enabled = []
    plugins["enabled"] = enabled
for name in ("gbrain-reflex", "hermes-context-manager", "gbrain-memory-flush"):
    if name not in enabled:
        enabled.append(name)
        changed = True
ext = plugins.get("external_dirs")
if not isinstance(ext, list):
    plugins["external_dirs"] = ["/data/plugins", "/var/lib/hermes/plugins"]
    changed = True
else:
    for d in ("/data/plugins", "/var/lib/hermes/plugins"):
        if d not in ext:
            ext.append(d)
            changed = True

if changed:
    path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
PY
      chown hermes:hermes "$cfg" 2>/dev/null || true
    fi
  '';
}
