# Hermes Agent — hermes-pnp consumer.
# RAM/CPU caps, admin socket, sudo CLI: ./runtime.nix
# Site extras (Composio, OneDrive): ./modules/
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
    ./modules/composio.nix
    ./modules/onedrive.nix
  ];

  services.hermesPnP = {
    enable = true;
    environmentFiles = [ config.sops.templates.hermesEnv.path ];

    # One workspace for gateway (terminal.cwd) + WebUI; stateDir root
    # remaps to /data in the OCI jails (whole-tree view). OneDrive still
    # lands in ${stateDir}/workspace/onedrive.
    workspace = "${config.services.hermes-agent.stateDir}";

    container.enable = true;

    browser.package = pkgs.brave;
    browser.gate.publicUrl = "https://browser.${settings.domain}/";
    browser.maxTabs = 3;

    models.low = { provider = "deepseek"; model = "deepseek-v4-flash"; }; # cheap helper, cron
    models.medium = { provider = "deepseek"; model = "deepseek-v4-pro"; }; # workhorse, delegation
    models.high = { provider = "xai-oauth"; model = "grok-4.6"; }; # session voice + fallback

    plugins = [
      "model-router"
      "tool-call-coherency"
      "secret-handoff"
      "git-hook"
    ];

    toolbox.extraPackages = [ pkgs.sops ];

    mcpProxy.enable = true;
    hmc.enable = true;
    gbrain.enable = true;
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
      # hermes doctor reports v0 if this key is missing
      _config_version = 33;

      # grok-4.6 window is 500k; 200k is the input-price cliff, not the limit.
      # Router hops use the live catalog. threshold_tokens keeps grok under the cliff.
      model.context_length = 500000;

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
        target_ratio = 0.15;
        protect_last_n = 8;
        proactive_prune_tokens = 24000;
        proactive_prune_min_result_chars = 2000;
        proactive_prune_min_reclaim_tokens = 2048;
        idle_compact_after_seconds = 1800;
      };

      delegation.max_concurrent_children = 5;

      cron.wrap_response = false;

      security = {
        allow_lazy_installs = false;
        allow_private_urls = true;
      };

      approvals.timeout = 120;

      web = {
        search_backend = "xai";
        extract_backend = "firecrawl";
      };

      timezone = settings.timeZone;

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

  # WebUI: LAN Caddy + Cloudflare Tunnel. Browser gate: LAN/Tailscale only.
  services.caddy.proxyServices."${webuiHost}" = webuiPort;
  services.caddy.proxyServices."browser.${settings.domain}" = 4848;
  services.cloudflareTunnel.proxyServices."${webuiHost}" = webuiPort;
}
