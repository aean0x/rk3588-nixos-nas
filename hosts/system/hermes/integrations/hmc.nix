# hermes-context-manager — pinned upstream, config.yaml only.
#
# No plugin.py / config.py overlay. Upstream 0.3.4+ already mutates tool
# outputs in post_tool_call + materialize_view on pre_llm_call.
# Native Hermes owns LLM compact (compression.threshold_tokens). HMC does
# cheap per-tool work only (truncation / code_filter / dedup / short_circuit).
{
  lib,
  pkgs,
  hermes,
  ...
}:
let
  hmcRev = "3f775efd48e878679e8fd4290b96968880fed6f7";
  hmcSrc = pkgs.fetchFromGitHub {
    owner = "entrepeneur4lyf";
    repo = "hermes-context-manager";
    rev = hmcRev;
    hash = "sha256-aQMKhWN9KVfpgbIbcvlGgTZHZ4xC/ATgJkz8btofM7Y=";
  };

  # Percent is of the *probed* model window (HMC does not read
  # model.context_length). 0.30 of Grok ~500k ≈ 150k — after native's 60k
  # fire. background_compression stays off so the two LLM compactors never
  # summarize the same range.
  hmcConfig = pkgs.writeText "hermes-context-manager-config.yaml" ''
    # Managed by NixOS (integrations/hmc.nix). Pin ${hmcRev}.
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
    rm -rf "$out/.github" "$out/tests" "$out/.gitignore"
    cp ${hmcConfig} "$out/config.yaml"
  '';
in
{
  _module.args.hmcPluginSrc = hmcPluginSrc;
}
