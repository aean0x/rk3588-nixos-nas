# First-party plugins + MCP clients. Catalog: ./AGENTS.md
#
# Pattern (all plugins, including HMC):
#   materialize → /var/lib/hermes/plugins/<name>
#   discover    → $HERMES_HOME/plugins/<name>  (relative symlink ../../plugins/<name>)
#
# Hermes ≥0.19/0.20 scans ONLY $HERMES_HOME/plugins (+ optional ~/.hermes/plugins if
# different, + bundled). There is NO plugins.external_dirs (skills-only key).
# One install shape everywhere — no dual full copies, no special-case fork.
{
  lib,
  pkgs,
  ...
}:
let
  pluginsDir = ./plugins;

  # Force-managed first-party plugins (source under integrations/plugins/).
  # HMC is fetched in context-manager.nix with the same materialize+symlink layout.
  managedPluginNames = [
    "gbrain-retrieval-reflex"
    "gbrain-memory-flush"
    "tool-call-coherency"
    "projects-auto-commit"
    "model-router"
  ];

  # plugins.enabled — leave empty for user opt-in; list names to force-enable.
  enabledPlugins = [
    "gbrain-retrieval-reflex"
    "gbrain-memory-flush"
    "tool-call-coherency"
    "projects-auto-commit"
    "model-router"
    "hermes-context-manager"
  ];

  enabledPluginsJson = builtins.toJSON enabledPlugins;

  # Canonical paths (host). Container stateDir maps .hermes → /data/.hermes and
  # /var/lib/hermes/plugins → /data/plugins when those bind mounts exist.
  hermesHomePlugins = "/var/lib/hermes/.hermes/plugins";
  materializeRoot = "/var/lib/hermes/plugins";
in
{
  imports = [
    ./mcp # maton stdio wrapper; gbrain HTTP client stays in ../gbrain.nix
  ];

  # Declarative allow-list (module SoT); activation also reconciles live config.yaml.
  services.hermes-agent.settings.plugins = {
    enabled = enabledPlugins;
  };

  system.activationScripts.hermes-integrations-plugins = lib.stringAfter [
    "users"
    "groups"
    "hermes-agent-setup"
    "hermes-toolbox"
  ] ''
    # materialize + relative symlink into discovery root (same shape as HMC).
    install_plugin_tree() {
      local name="$1" src="$2"
      local dest="${materializeRoot}/$name"
      local link="${hermesHomePlugins}/$name"
      mkdir -p "$dest" "${hermesHomePlugins}"
      # Drop previous discovery entry if it was a real dir (pre-unify dual copy).
      if [ -e "$link" ] && [ ! -L "$link" ]; then
        rm -rf "$link"
      fi
      # Refresh materialize tree (no webui / pycache).
      find "$dest" -mindepth 1 -maxdepth 1 ! -name webui ! -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
      ${pkgs.rsync}/bin/rsync -a --delete \
        --exclude 'webui/' --exclude '__pycache__/' --exclude '*.pyc' \
        "$src"/ "$dest"/
      chown -R hermes:hermes "$dest" 2>/dev/null || true
      find "$dest" -type d -exec chmod 2770 {} \; 2>/dev/null || true
      find "$dest" -type f -exec chmod 0640 {} \; 2>/dev/null || true
      # Relative: $HERMES_HOME/plugins/<name> → ../../plugins/<name>
      # works on host (/var/lib/hermes) and container (/data) with matching layout.
      ln -sfn ../../plugins/"$name" "$link"
      chown -h hermes:hermes "$link" 2>/dev/null || true
    }

    ${lib.concatMapStrings (name: ''
      install_plugin_tree ${name} ${pluginsDir}/${name}
    '') managedPluginNames}

    # Reconcile plugins.enabled; strip dead plugins.external_dirs (skills-only key).
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
if not isinstance(data, dict):
    sys.exit(0)

changed = False
plugins = data.setdefault("plugins", {})
if not isinstance(plugins, dict):
    plugins = {}
    data["plugins"] = plugins
    changed = True

# Dead key: Hermes never reads plugins.external_dirs (skills.external_dirs only).
if "external_dirs" in plugins:
    del plugins["external_dirs"]
    changed = True

enabled = list(plugins.get("enabled") or [])
want = ${enabledPluginsJson}
for name in want:
    if name not in enabled:
        enabled.append(name)
        changed = True
if plugins.get("enabled") != enabled:
    plugins["enabled"] = enabled
    changed = True

if changed:
    path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
PY
      chown hermes:hermes "$cfg" 2>/dev/null || true
    fi
  '';
}
