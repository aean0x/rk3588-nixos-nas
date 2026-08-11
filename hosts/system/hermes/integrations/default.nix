# First-party plugins + MCP clients. Catalog: ./AGENTS.md
{
  lib,
  pkgs,
  ...
}:
let
  pluginsDir = ./plugins;

  # Single source of truth for plugins.enabled (settings + live config reconcile).
  # hermes-context-manager is installed by ../context-manager.nix (upstream pin).
  enabledPlugins = [
    "hermes-context-manager"
    "gbrain-retrieval-reflex"
    "gbrain-memory-flush"
    "tool-call-coherency"
    "projects-auto-commit"
    "model-router"
  ];

  # Trees under plugins/ that we force-install (not HMC overlay alone).
  managedPluginNames = [
    "gbrain-retrieval-reflex"
    "gbrain-memory-flush"
    "tool-call-coherency"
    "projects-auto-commit"
    "model-router"
  ];

  # JSON list for the activation Python reconciler.
  enabledPluginsJson = builtins.toJSON enabledPlugins;
in
{
  imports = [
    ./mcp
  ];

  services.hermes-agent.settings.plugins = {
    external_dirs = [
      "/data/plugins"
      "/var/lib/hermes/plugins"
    ];
    enabled = enabledPlugins;
  };

  # Install force-managed plugin code + ensure live config allow-list.
  system.activationScripts.hermes-integrations = lib.stringAfter [
    "hermes-agent-setup"
    "hermes-toolbox"
  ] ''
    install_plugin_tree() {
      name="$1"
      src_dir="$2"
      for base in /var/lib/hermes/.hermes/plugins /var/lib/hermes/plugins; do
        [ -d "$(dirname "$base")" ] || continue
        install -d -m 0755 -o hermes -g hermes "$base/$name"
        # Core plugin files
        if [ -f "$src_dir/plugin.yaml" ]; then
          install -m 0644 -o hermes -g hermes "$src_dir/plugin.yaml" "$base/$name/plugin.yaml"
        fi
        if [ -f "$src_dir/__init__.py" ]; then
          install -m 0644 -o hermes -g hermes "$src_dir/__init__.py" "$base/$name/__init__.py"
        fi
        # Optional extras (not webui — that is store-only for HERMES_WEBUI_EXTENSION_DIR)
        for extra in "$src_dir"/*; do
          [ -e "$extra" ] || continue
          base_name="$(basename "$extra")"
          case "$base_name" in
            plugin.yaml|__init__.py|webui|__pycache__) continue ;;
          esac
          if [ -f "$extra" ]; then
            install -m 0644 -o hermes -g hermes "$extra" "$base/$name/$base_name"
          fi
        done
      done
    }

    ${lib.concatMapStringsSep "\n" (name: ''
      install_plugin_tree ${name} ${pluginsDir}/${name}
    '') managedPluginNames}

    # Drop retired plugin dirs (static index; superseded).
    rm -rf /var/lib/hermes/.hermes/plugins/gbrain-reflex \
      /var/lib/hermes/plugins/gbrain-reflex \
      /var/lib/hermes/.hermes/plugins/web-backends-fix \
      /var/lib/hermes/plugins/web-backends-fix

    cfg=/var/lib/hermes/.hermes/config.yaml
    if [ -f "$cfg" ]; then
      ${pkgs.python3}/bin/python3 - "$cfg" <<'PY'
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit(0)

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text()) or {}
changed = False
plugins = data.setdefault("plugins", {})
if not isinstance(plugins, dict):
    plugins = {}
    data["plugins"] = plugins
    changed = True
enabled = plugins.get("enabled")
if not isinstance(enabled, list):
    enabled = []
    plugins["enabled"] = enabled
    changed = True
desired = json.loads(${lib.strings.escapeShellArg enabledPluginsJson})
for retired in ("gbrain-reflex", "web-backends-fix"):
    if retired in enabled:
        enabled[:] = [n for n in enabled if n != retired]
        changed = True
for name in desired:
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
    fi
  '';
}
