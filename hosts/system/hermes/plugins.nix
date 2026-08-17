# Hermes plugins: composer catalog + HMC host pin + host skills.
# Plugin *code* lives in flake input hermes-pnp. HMC is a host pin
# (not in the composer catalog) because its config.yaml is site-specific.
{
  lib,
  pkgs,
  hermes,
  ...
}: let
  # --- hermes-context-manager, pinned upstream, config.yaml only. ---
  # No plugin.py / config.py overlay. Upstream 0.3.4+ already mutates tool
  # outputs in post_tool_call + materialize_view on pre_llm_call.
  # Native Hermes owns LLM compact (compression.threshold_tokens). HMC does
  # cheap per-tool work only (truncation / code_filter / dedup / short_circuit).
  hmcRev = "3f775efd48e878679e8fd4290b96968880fed6f7";
  hmcSrc = pkgs.fetchFromGitHub {
    owner = "entrepeneur4lyf";
    repo = "hermes-context-manager";
    rev = hmcRev;
    hash = "sha256-aQMKhWN9KVfpgbIbcvlGgTZHZ4xC/ATgJkz8btofM7Y=";
  };

  # Percent is of the *probed* model window (HMC does not read
  # model.context_length). Unused while background_compression is off —
  # native owns LLM compact (DeepSeek ~180k / Grok ~150k).
  hmcConfig = pkgs.writeText "hermes-context-manager-config.yaml" ''
    # Managed by NixOS (plugins.nix). Pin ${hmcRev}.
    enabled: true
    debug: false

    manual_mode:
      enabled: false
      automatic_strategies: true

    compress:
      max_context_percent: ${toString hermes.compressionThreshold}
      min_context_percent: ${toString hermes.compressionThreshold}
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
      max_lines: 30
      head_lines: 10
      tail_lines: 6
      min_content_length: 500

    # Native ContextCompressor owns LLM summarization. Do not double-fire.
    background_compression:
      enabled: false
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

  hmcPluginSrc = pkgs.runCommand "hermes-context-manager" { } ''
    mkdir -p "$out"
    cp -a ${hmcSrc}/. "$out/"
    chmod -R u+w "$out"
    rm -rf "$out/.github" "$out/tests" "$out/.gitignore"
    cp ${hmcConfig} "$out/config.yaml"
  '';

  skillsDir = ./skills;
  managedSkills = [
    "retrieval-reflex"
    "gbrain-http-auth"
  ];
in {
  services.hermesPnP.extraPlugins.hermes-context-manager = hmcPluginSrc;

  # Host skills + HMC state. Plugin trees are installed by hermes-pnp.
  system.activationScripts.hermes-integrations-skills =
    lib.stringAfter [
      "users"
      "groups"
      "hermes-agent-setup"
    ] ''
      install -d -m 2770 -o hermes -g hermes ${hermes.hermesHome}/hmc_state

      ${lib.concatMapStrings (name: ''
          install -d -m 0755 -o hermes -g hermes ${hermes.skills.host}/${name}
          install -m 0644 -o hermes -g hermes ${skillsDir}/${name}/SKILL.md \
            ${hermes.skills.host}/${name}/SKILL.md
        '')
        managedSkills}
    '';
}
