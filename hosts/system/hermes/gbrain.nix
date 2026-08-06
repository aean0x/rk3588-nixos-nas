# Hermes ↔ G-Brain: registry, MCP serve, native retrieval-reflex plugin.
#
# Agent path: MCP `gbrain serve` (put_page / query / get_page /
# volunteer_context / …). Never shell `gbrain` CLI — PGLite single-writer.
#
# Push/reflex (docs/guides/push-context.md + resolve-ipc.ts):
#   - ambient: plugin gbrain-retrieval-reflex → unix resolve socket owned by
#     live `gbrain serve` (candidates in, pointers out; no second PGLite)
#   - op: MCP volunteer_context (agent/skill multi-turn window)
# No host static pointer JSON.
#
# MCP child must INHERIT agent env (ZEROENTROPY_API_KEY from /run/hermes.env).
# Do not mkForce env={HOME,PATH} only — that strips embeddings keys from serve.
# PATH is fixed via a thin wrapper instead.
#
# Maintenance: gbrain MCP surfaces; Hermes cron via MCP tools only.
# Do NOT reintroduce exclusive consolidate/dream host wrappers.
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

  # Preserve parent env (secrets); only pin PATH for bun-global gbrain.
  # Installed to /var/lib/hermes/bin → container /data/bin (not a bare nix-store
  # path in mcp config — MCP child runs inside the container).
  gbrainMcpServeScript = pkgs.writeShellScript "gbrain-mcp-serve" ''
    export HOME="''${HOME:-/home/hermes}"
    export PATH="/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/usr/local/bin:/usr/bin:/bin''${PATH:+:$PATH}"
    exec gbrain serve "$@"
  '';
  # Container-visible path (stateDir bind).
  gbrainMcpServeCmd = "/data/bin/gbrain-mcp-serve";
in
{
  services.hermes-agent = {
    mcpServers.gbrain = {
      command = gbrainMcpServeCmd;
      args = [ ];
      connect_timeout = 120;
      timeout = 120;
      # Intentionally no env mkForce — inherit ZEROENTROPY_API_KEY and friends
      # from the hermes-agent process (environmentFiles → /run/hermes.env).
    };

    environment = {
      HERMES_MEMORY_REGISTRY = "/data/memory/registry.json";
      GBRAIN_AUDIT_DIR = "/home/hermes/.gbrain/audit";
    };
  };

  # Purge former exclusive-CLI surface (one generation of explicit disable is
  # enough if units still linger; units no longer defined elsewhere).
  systemd.services.hermes-gbrain-consolidate.enable = lib.mkForce false;
  systemd.timers.hermes-gbrain-consolidate.enable = lib.mkForce false;
  systemd.services.gbrain-dream.enable = lib.mkForce false;
  systemd.timers.gbrain-dream.enable = lib.mkForce false;
  systemd.services.gbrain-embed.enable = lib.mkForce false;
  systemd.timers.gbrain-embed.enable = lib.mkForce false;
  systemd.services.gbrain-nightly.enable = lib.mkForce false;
  systemd.timers.gbrain-nightly.enable = lib.mkForce false;

  system.activationScripts.hermes-memory-manifest = lib.stringAfter [ "hermes-agent-setup" ] ''
    # seed_if_missing DEST SRC MODE — Hermes owns content after first install.
    seed_if_missing() {
      dest="$1"; src="$2"; mode="$3"
      if [ ! -e "$dest" ]; then
        install -D -m "$mode" -o hermes -g hermes "$src" "$dest"
        echo "hermes-seed: created $dest"
      fi
    }

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    # MCP serve wrapper: inherits agent env (ZEROENTROPY_*), fixes PATH for bun gbrain.
    install -m 0755 -o hermes -g hermes ${gbrainMcpServeScript} \
      /var/lib/hermes/bin/gbrain-mcp-serve
    # Purge agent-visible exclusive CLI + host static-pointer workaround.
    rm -f /var/lib/hermes/bin/gbrain-exclusive-cli \
      /var/lib/hermes/bin/hermes-gbrain-consolidate-inner \
      /var/lib/hermes/bin/hermes-gbrain-embed-inner \
      /var/lib/hermes/bin/hermes-gbrain-consolidate \
      /var/lib/hermes/bin/hermes-gbrain-dream \
      /var/lib/hermes/bin/hermes-gbrain-embed \
      /var/lib/hermes/bin/hermes-gbrain-nightly \
      /var/lib/hermes/bin/hermes-gbrain-exclusive
    rm -f /var/lib/hermes/workspace/gbrain-pointer-index.json
    # Retire static-index plugin; install native IPC plugin below.
    rm -rf /var/lib/hermes/.hermes/plugins/gbrain-reflex \
      /var/lib/hermes/plugins/gbrain-reflex

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

    # ── Workspace: GBRAIN.md is infra policy (always managed) ──
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/workspace
    install -m 0640 -o hermes -g hermes ${./workspace/GBRAIN.md} \
      /var/lib/hermes/workspace/GBRAIN.md

    # ── Infra plugins (force-managed code; not agent content) ──
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
    install_plugin_tree gbrain-retrieval-reflex ${./plugins/gbrain-retrieval-reflex}
    install_plugin_tree gbrain-memory-flush ${./plugins/gbrain-memory-flush}
    install_plugin_tree tool-call-coherency ${./plugins/tool-call-coherency}
    install_plugin_tree projects-auto-commit ${./plugins/projects-auto-commit}

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/.hermes/scripts
    install -m 0755 -o hermes -g hermes ${./scripts/projects_auto_commit.py} \
      /var/lib/hermes/.hermes/scripts/projects_auto_commit.py
    install -m 0755 -o hermes -g hermes ${./scripts/git-credential-github-env} \
      /var/lib/hermes/.hermes/scripts/git-credential-github-env
    if command -v git >/dev/null 2>&1; then
      sudo -u hermes git config --global credential.helper \
        /var/lib/hermes/.hermes/scripts/git-credential-github-env || true
      sudo -u hermes git config --global credential.useHttpPath true || true
    fi

    # retrieval-reflex policy is infra-owned (MCP-only ladder); reinstall each activation.
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/skills/retrieval-reflex
    install -m 0644 -o hermes -g hermes ${./skills/retrieval-reflex/SKILL.md} \
      /var/lib/hermes/skills/retrieval-reflex/SKILL.md

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain/audit
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/brain

    if [ ! -e /home/hermes ]; then
      ln -sfn /var/lib/hermes/home /home/hermes
    elif [ ! -L /home/hermes ] && [ ! -d /home/hermes ]; then
      ln -sfn /var/lib/hermes/home /home/hermes
    fi

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
# Match Nix mcpServers.gbrain: /data/bin wrapper inherits agent env.
desired_mcp = {
    "command": "${gbrainMcpServeCmd}",
    "args": [],
    "connect_timeout": 120,
    "timeout": 120,
    "enabled": True,
}
# Drop legacy bare command + env strip if still present.
cur = mcp.get("gbrain") or {}
if cur.get("command") != desired_mcp["command"] or cur.get("args") != [] or "env" in cur:
    mcp["gbrain"] = desired_mcp
    changed = True
elif not cur.get("enabled", True):
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
desired_plugins = [
    "hermes-context-manager",
    "gbrain-retrieval-reflex",
    "gbrain-memory-flush",
    "tool-call-coherency",
    "projects-auto-commit",
]
# Drop retired static-index plugin if still listed.
if "gbrain-reflex" in enabled:
    enabled[:] = [n for n in enabled if n != "gbrain-reflex"]
    changed = True
for name in desired_plugins:
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
