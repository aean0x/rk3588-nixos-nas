# hermes-context-manager (HMC) — silent-first context optimization plugin.
# Upstream: https://github.com/entrepeneur4lyf/hermes-context-manager
#
# Installs a pinned commit into /var/lib/hermes/plugins/hermes-context-manager
# (plugins.external_dirs) and a relative symlink under $HERMES_HOME/plugins so
# the 0.19 plugin loader discovers it in container mode (HERMES_HOME=/data/.hermes).
#
# After deploy: restart the gateway so hooks load (`hermes gateway restart` or
# `systemctl restart hermes-agent`), then `/hmc status` in chat.
# Overlay under plugins/hermes-context-manager-overlay fixes live mutation hooks.
{
  lib,
  pkgs,
  ...
}:
let
  # Pin: main @ 2026-era; bump rev+hash to update.
  hmcRev = "3f775efd48e878679e8fd4290b96968880fed6f7";
  hmcSrc = pkgs.fetchFromGitHub {
    owner = "entrepeneur4lyf";
    repo = "hermes-context-manager";
    rev = hmcRev;
    hash = "sha256-aQMKhWN9KVfpgbIbcvlGgTZHZ4xC/ATgJkz8btofM7Y=";
  };

  # From upstream config.yaml.example: truncation + code_filter + background_compression
  # on; dashboard remains opt-in via `/hmc dashboard action=start` (no config key).
  hmcConfig = pkgs.writeText "hermes-context-manager-config.yaml" ''
    # Managed by NixOS (hosts/system/hermes/context-manager.nix).
    # Upstream pin: entrepeneur4lyf/hermes-context-manager@${hmcRev}
    # Restart gateway after deploy for changes to take effect.

    enabled: true
    debug: false

    manual_mode:
      enabled: false
      automatic_strategies: true

    compress:
      # Absolute budget: large windows (grok 500k) otherwise never compress before 200k+.
      max_context_tokens: 120000
      max_context_percent: 0.24
      min_context_percent: 0.24
      protected_tools:
        - write_file
        - patch

    strategies:
      deduplication:
        enabled: true
        protected_tools: []
      purge_errors:
        enabled: true
        turns: 4
        protected_tools: []

    short_circuits:
      enabled: true

    truncation:
      enabled: true
      max_lines: 40
      head_lines: 12
      tail_lines: 8
      min_content_length: 500

    background_compression:
      enabled: true
      protect_recent_turns: 3

    analytics:
      enabled: true
      retention_days: 90
      db_path: ""

    code_filter:
      enabled: true
      languages:
        - python
        - javascript
        - typescript
        - rust
        - go
      min_lines: 30
      preserve_docstrings: true
  '';

  pluginDest = "/var/lib/hermes/plugins/hermes-context-manager";
  # Relative from $HERMES_HOME/plugins → ../../plugins/hermes-context-manager
  # works on host (/var/lib/hermes) and in container (/data).
  hermesHomePlugins = "/var/lib/hermes/.hermes/plugins";
in
{
  system.activationScripts.hermes-context-manager = lib.stringAfter [
    "hermes-agent-setup"
    "hermes-toolbox"
  ] ''
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/plugins
    install -d -m 2770 -o hermes -g hermes ${hermesHomePlugins}

    dest=${pluginDest}
    # Refresh plugin tree from pinned source (preserve nothing under dest).
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -a ${hmcSrc}/. "$dest/"
    # Drop VCS / CI noise from the live tree.
    rm -rf "$dest/.github" "$dest/tests" "$dest/.gitignore" 2>/dev/null || true

    install -m 0640 -o hermes -g hermes ${hmcConfig} "$dest/config.yaml"

    # Overlay: real live-mutation hooks (transform_tool_result + pre_api_request)
    # and CompressConfig.max_context_tokens. Upstream post_tool_call is observational
    # only — without this overlay HMC reports ~1% context and 0 tokens saved.
    overlay=${./plugins/hermes-context-manager-overlay}
    if [ -f "$overlay/plugin.py" ]; then
      install -m 0640 -o hermes -g hermes "$overlay/plugin.py" \
        "$dest/hermes_context_manager/plugin.py"
    fi
    if [ -f "$overlay/config.py" ]; then
      install -m 0640 -o hermes -g hermes "$overlay/config.py" \
        "$dest/hermes_context_manager/config.py"
    fi

    chown -R hermes:hermes "$dest"
    find "$dest" -type d -exec chmod 2770 {} \;
    find "$dest" -type f -exec chmod 0640 {} \;

    # Discovery path: $HERMES_HOME/plugins (0.19 loads here; external_dirs alone is not enough).
    # Relative symlink so host + container (stateDir → /data) both resolve.
    ln -sfn ../../plugins/hermes-context-manager ${hermesHomePlugins}/hermes-context-manager
    chown -h hermes:hermes ${hermesHomePlugins}/hermes-context-manager

    # State dir for analytics / session indexes (plugin default under HERMES_HOME).
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/hmc_state

    echo "hermes-context-manager: installed ${hmcRev} → $dest"
  '';
}
