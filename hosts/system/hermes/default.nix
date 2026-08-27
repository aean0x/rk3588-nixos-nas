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

      # Preference: long builds. Upstream default is 180s.
      terminal.timeout = 300;

      # Grok-4.6 input-price cliff. PnP seeds per-model ratios (flash 0.95 /
      # pro 0.26 / grok 0.28); this cap still wins when lower. Do not set
      # model.context_length — that stamps every model until the first switch.
      compression.threshold_tokens = 180000;

      # Preference: 8 GiB jail. Upstream default is 10.
      delegation.max_concurrent_children = 5;

      cron.wrap_response = false;

      security = {
        allow_lazy_installs = false;
        allow_private_urls = true;
      };

      web = {
        search_backend = "xai";
        extract_backend = "firecrawl";
      };

      timezone = settings.timeZone;

      agent = {
        # Preference: host/cost cap. Upstream default is unlimited (null).
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
