# Hermes ↔ G-Brain: registry, MCP serve, exclusive host timers.
#
# Supported model (gbrain INSTALL_FOR_AGENTS + Hermes MCP):
#   - Agent installs gbrain (`bun install -g`) and uses MCP serve for read/write.
#   - Host jobs share one exclusive path (hermes-gbrain-exclusive):
#       flock → stop hermes-agent → wait (no serve / no .gbrain-lock) → CLI → restart
#   - systemd Conflicts= serializes consolidate / dream / embed oneshots.
#   - Ad-hoc CLI: /var/lib/hermes/bin/gbrain-exclusive-cli (refuses if agent/serve up).
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

  exclusiveScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-exclusive";
    runtimeInputs = runtime;
    excludeShellChecks = [
      "SC2329"
      "SC2181"
      "SC2016"
    ];
    text = builtins.readFile ./scripts/hermes-gbrain-exclusive.sh;
  };

  consolidateScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-consolidate";
    runtimeInputs = runtime ++ [ exclusiveScript ];
    # trap cleanup() looks unused to shellcheck
    # SC2016: intentional single-quoted bash -c so $HOME expands in hermes shell
    excludeShellChecks = [
      "SC2329"
      "SC2181"
      "SC2016"
    ];
    text = builtins.readFile ./scripts/hermes-gbrain-consolidate.sh;
  };

  embedScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-embed";
    runtimeInputs = runtime ++ [ exclusiveScript ];
    excludeShellChecks = [
      "SC2329"
      "SC2181"
      "SC2016"
    ];
    text = builtins.readFile ./scripts/hermes-gbrain-embed.sh;
  };

  dreamScript = pkgs.writeShellApplication {
    name = "hermes-gbrain-dream";
    runtimeInputs = runtime ++ [ exclusiveScript ];
    excludeShellChecks = [
      "SC2329"
      "SC2181"
      "SC2016"
    ];
    text = builtins.readFile ./scripts/hermes-gbrain-dream.sh;
  };

  exclusiveCliScript = pkgs.writeShellApplication {
    name = "gbrain-exclusive-cli";
    runtimeInputs = runtime;
    excludeShellChecks = [
      "SC2329"
      "SC2181"
      "SC2016"
    ];
    text = builtins.readFile ./scripts/gbrain-exclusive-cli.sh;
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

  # Mutual exclusion across the three oneshots (PGLite single-writer).
  gbrainJobConflicts = [
    "hermes-gbrain-consolidate.service"
    "gbrain-dream.service"
    "gbrain-embed.service"
  ];
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
    description = "Hermes memory snapshot + G-Brain inbox import (exclusive CLI, hermes stopped)";
    after = [ "hermes-agent.service" ];
    conflicts = lib.filter (u: u != "hermes-gbrain-consolidate.service") gbrainJobConflicts;
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
    description = "G-Brain overnight dream (exclusive CLI, hermes stopped)";
    after = [ "hermes-agent.service" ];
    conflicts = lib.filter (u: u != "gbrain-dream.service") gbrainJobConflicts;
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${lib.getExe dreamScript}";
      StandardOutput = "journal";
      StandardError = "journal";
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
    description = "G-Brain embed --stale (exclusive CLI, hermes stopped)";
    after = [ "hermes-agent.service" ];
    conflicts = lib.filter (u: u != "gbrain-embed.service") gbrainJobConflicts;
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${lib.getExe embedScript}";
      StandardOutput = "journal";
      StandardError = "journal";
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
    exclusiveScript
    consolidateScript
    embedScript
    dreamScript
    exclusiveCliScript
  ];

  system.activationScripts.hermes-memory-manifest = lib.stringAfter [ "hermes-agent-setup" ] ''
    # seed_if_missing DEST SRC MODE — Hermes owns content after first install.
    # Infra never overwrites agent edits to pointer index, GBRAIN.md, or skills.
    seed_if_missing() {
      dest="$1"; src="$2"; mode="$3"
      if [ ! -e "$dest" ]; then
        install -D -m "$mode" -o hermes -g hermes "$src" "$dest"
        echo "hermes-seed: created $dest"
      fi
    }

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    install -m 0755 -o root -g hermes ${lib.getExe consolidateInnerScript} \
      /var/lib/hermes/bin/hermes-gbrain-consolidate-inner
    # Exclusive CLI guard: refuse if hermes-agent or gbrain serve holds PGLite.
    # Force-managed (not seed-once) so prevention logic stays current.
    install -m 0755 -o root -g hermes ${lib.getExe exclusiveCliScript} \
      /var/lib/hermes/bin/gbrain-exclusive-cli

    # ── Always managed (memory contract / registry) ──
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
        echo 'Durable knowledge → GBrain MCP put_page (ops/gbrain-protocol).'
      } > /var/lib/hermes/.hermes/memories/MEMORY.md
      chown hermes:hermes /var/lib/hermes/.hermes/memories/MEMORY.md
      chmod 0640 /var/lib/hermes/.hermes/memories/MEMORY.md
    fi

    # ── Hermes-owned content (seed once; agent maintains) ──
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/workspace
    seed_if_missing /var/lib/hermes/workspace/GBRAIN.md \
      ${./workspace/GBRAIN.md} 0640
    seed_if_missing /var/lib/hermes/workspace/gbrain-pointer-index.json \
      ${./workspace/gbrain-pointer-index.json} 0640

    # ── Infra plugins (force-managed code; not agent content) ──
    # Prefer $HERMES_HOME/plugins; mirror to external_dirs for dual discovery.
    install_plugin_tree() {
      name="$1"; src_dir="$2"
      for base in /var/lib/hermes/.hermes/plugins /var/lib/hermes/plugins; do
        [ -d "$(dirname "$base")" ] || continue
        install -d -m 0755 -o hermes -g hermes "$base/$name"
        install -m 0644 -o hermes -g hermes "$src_dir/plugin.yaml" \
          "$base/$name/plugin.yaml"
        install -m 0644 -o hermes -g hermes "$src_dir/__init__.py" \
          "$base/$name/__init__.py"
      done
    }
    install_plugin_tree gbrain-reflex ${./plugins/gbrain-reflex}
    install_plugin_tree gbrain-memory-flush ${./plugins/gbrain-memory-flush}
    install_plugin_tree tool-call-coherency ${./plugins/tool-call-coherency}
    install_plugin_tree projects-auto-commit ${./plugins/projects-auto-commit}

    # Host scripts used by plugins / agent (force-managed; not agent content).
    # Live path in container: /data/.hermes/scripts (HERMES_HOME bind).
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/.hermes/scripts
    install -m 0755 -o hermes -g hermes ${./scripts/projects_auto_commit.py} \
      /var/lib/hermes/.hermes/scripts/projects_auto_commit.py
    install -m 0755 -o hermes -g hermes ${./scripts/git-credential-github-env} \
      /var/lib/hermes/.hermes/scripts/git-credential-github-env
    # Push auth for monorepo auto-commit: env GITHUB_PAT via credential helper.
    if command -v git >/dev/null 2>&1; then
      sudo -u hermes git config --global credential.helper \
        /var/lib/hermes/.hermes/scripts/git-credential-github-env || true
      sudo -u hermes git config --global credential.useHttpPath true || true
    fi

    # retrieval-reflex policy skill — Hermes owns after seed
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/skills
    seed_if_missing /var/lib/hermes/skills/retrieval-reflex/SKILL.md \
      ${./skills/retrieval-reflex/SKILL.md} 0644
    if [ -d /var/lib/hermes/skills/retrieval-reflex ]; then
      chown -R hermes:hermes /var/lib/hermes/skills/retrieval-reflex
    fi

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

    # Ensure plugins.enabled + gbrain MCP survive deep-merge races (infra only).
    # Does not touch agent-added MCP servers (e.g. robinhood).
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

plugins = data.setdefault("plugins", {})
if not isinstance(plugins, dict):
    plugins = {}
    data["plugins"] = plugins
enabled = plugins.get("enabled")
if not isinstance(enabled, list):
    enabled = []
    plugins["enabled"] = enabled
for name in (
    "gbrain-reflex",
    "hermes-context-manager",
    "gbrain-memory-flush",
    "tool-call-coherency",
    "projects-auto-commit",
):
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
