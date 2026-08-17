# Hermes Agent — hermes-pnp consumer + official settings + public edge.
#
# Host runtime (RAM caps, sudo CLI) is ./runtime.nix.
# Other host leftovers (GBrain yaml/credential, Composio, OneDrive,
# workstation) are modules/.
{
  config,
  pkgs,
  settings,
  inputs,
  ...
}:
let
  webuiPort = 8787;
  webuiHost = "archimedes.${settings.domain}";
in
{
  imports = [
    inputs.hermes-pnp.nixosModules.default
    ./runtime.nix
    ./modules/gbrain.nix
    ./modules/composio.nix
    ./modules/onedrive.nix
    ./modules/workstation.nix
  ];

  services.hermesPnP = {
    enable = true;
    environmentFiles = [ config.sops.templates.hermesEnv.path ];

    plugins = [
      "model-router"
      "tool-call-coherency"
      "secret-handoff"
      "git-hook"
    ];

    toolbox.extraPackages = [ pkgs.sops ];

    browser.package = pkgs.brave;

    container.enable = true;

    hmc.enable = true;

    gbrain.enable = true;

    mcpProxy.enable = true;
  };

  services.hermes-agent = {
    enable = true;

    container.hostUsers = [ settings.adminUser ];

    addToSystemPackages = true;

    extraDependencyGroups = [
      "messaging"
      "firecrawl"
    ];

    settings = {
      # hermes doctor: missing key is reported as v0.
      _config_version = 33;

      # Display + compressor window. Applies to the default model only
      # (grok-4.6); after a router hop the live catalog window wins.
      # Native fire is min(ratio × live window, this cap). 180k is the
      # DeepSeek ceiling; Grok on the 200k pin hits the <512k 75% floor
      # first (~150k).
      model.context_length = 200000;

      stt = {
        provider = "openai";
        model = "whisper-1";
      };

      tts = {
        provider = "elevenlabs";
        elevenlabs = {
          voice_id = "DfE5EkknFF950NR6OMui";
          model_id = "eleven_flash_v2_5";
        };
      };

      toolsets = [ "all" ];

      # official terminal.timeout = 180; 300s for long NAS jobs
      terminal.timeout = 300;

      tool_output = {
        max_bytes = 6000;
        max_lines = 150;
      };

      compression = {
        threshold = 0.30;
        threshold_tokens = 180000;
        model_thresholds = {
          "deepseek-v4" = 0.18;
        };
        # official target_ratio = 0.20; 0.15 keeps more headroom on 8GiB
        target_ratio = 0.15;
        protect_last_n = 8;
        proactive_prune_tokens = 24000;
        proactive_prune_min_result_chars = 2000;
        # official min_reclaim = 4096; 2048 fires more often on this board
        proactive_prune_min_reclaim_tokens = 2048;
        idle_compact_after_seconds = 1800;
      };

      delegation.max_concurrent_children = 5;

      cron.wrap_response = false;

      security = {
        allow_lazy_installs = false;
        allow_private_urls = true;
      };

      # official approvals.timeout = 300; 120s is tighter for this box
      approvals.timeout = 120;

      web = {
        search_backend = "xai";
        extract_backend = "firecrawl";
      };

      timezone = "Europe/Berlin";

      agent = {
        max_turns = 80;
        api_max_retries = 8;
        disabled_toolsets = [
          "video"
          "video_gen"
          "spotify"
          "yuanbao"
          "computer_use"
        ];
      };
    };
  };

  services.caddy.proxyServices."${webuiHost}" = webuiPort;
  services.cloudflareTunnel.proxyServices."${webuiHost}" = webuiPort;
}
