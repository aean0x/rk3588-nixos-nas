# Hermes Agent — hermes-pnp consumer.
# RAM/CPU caps, admin socket, sudo CLI: ./runtime.nix
# Site extras (Composio, BankSync, open-banking, OpenAccountants,
# PolicyLayer, OneDrive): ./modules/
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
  # Desktop/app backend (`hermes serve`). Official backend.mode is blocked
  # when container.enable is on; run it on the host against the same HERMES_HOME.
  servePort = 9119;
  stateDir = config.services.hermes-agent.stateDir;
in
{
  imports = [
    inputs.hermes-pnp.nixosModules.default
    ./runtime.nix
    ./modules/composio.nix
    ./modules/banksync.nix
    ./modules/open-banking.nix
    ./modules/openaccountants.nix
    ./modules/onedrive.nix
    ./modules/policylayer.nix
    ./modules/webui-extensions.nix
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
    # Build-time auth import from a local browser profile (hermes-pnp
    # browser.profileImport). Source must exist on the BUILD machine;
    # absolute-path reads are impure, so switch with --impure:
    #   nixos-rebuild switch --impure
    # Seeds the sticky profile once (cookies/logins/prefs), then the
    # gate takes over. Keep off unless a profile exists to import.
    # browser.profileImport = {
    #   enable = true;
    #   source = "/home/alice/.config/BraveSoftware/Brave-Browser";
    #   # profileName = "Default"; # profile dir inside source
    #   # overwrite = false;
    # };

    # Library default after hermes-pnp #65 is medium. Keep high so grok
    # stays session voice; consumer fallback_model (deepseek-v4-pro)
    # still catches provider failure.
    model.default = "high";

    # Compaction intent (2026-09): grok compresses at 200k via the
    # threshold_tokens cap below — its sub-512k floor alone would force
    # 0.75 * 500k = 375k. DeepSeek keeps its real 1M window; the 0.30
    # ratios (= 300k) are dormant under the global cap until upstream
    # supports per-model absolute thresholds.
    models.low = { provider = "deepseek"; model = "deepseek-v4-flash"; compression_ratio = 0.30; }; # cheap helper, cron
    models.medium = { provider = "deepseek"; model = "deepseek-v4-pro"; compression_ratio = 0.30; }; # workhorse, delegation
    models.high = { provider = "xai-oauth"; model = "grok-4.6"; }; # session voice

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

      # "all" expands to every toolset, but the kanban toolset is
      # runtime-gated on the literal "kanban" entry in toolsets (see
      # tools/kanban_tools.py _profile_has_kanban_toolset), so it must be
      # listed explicitly to give the default profile orchestrator access.
      toolsets = [ "all" "kanban" ];

      # Preference: long builds. Upstream default is 180s.
      terminal.timeout = 300;

      # Grok-4.6 input-price cliff (~200k): the cap lets grok run to 200k
      # before compacting and still beats every per-model ratio (grok's
      # sub-512k floor alone would force 0.75 * 500k = 375k), so it also
      # holds DeepSeek at 200k despite the 0.30 * 1M = 300k ratios above.
      # Do not set model.context_length — that stamps every model until the
      # first switch.
      compression.threshold_tokens = 200000;

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

      # Grok is session voice; if it fails, land on the workhorse.
      fallback_model = {
        provider = "deepseek";
        model = "deepseek-v4-pro";
      };

      # Auxiliary falls back to OpenRouter when DeepSeek is down. Schema
      # default is a paid SKU; keep fallbacks on :free (live hygiene
      # 2026-09-02). Nested merge with composer slot seeds.
      auxiliary = {
        free_only = true;
        openrouter_model = "nvidia/nemotron-3-ultra-550b-a55b:free";
      };

      agent = {
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

  # WebUI: LAN Caddy + Cloudflare Tunnel.
  # hermes.<domain>: LAN/Tailscale alias → serve :9119 (no dashboard, no tunnel).
  # Browser gate: LAN/Tailscale, no tunnel.
  services.caddy.proxyServices."${webuiHost}" = webuiPort;
  services.caddy.proxyServices."hermes.${settings.domain}" = servePort;
  services.caddy.proxyUpstreamHost."hermes.${settings.domain}" = "127.0.0.1:${toString servePort}";
  services.caddy.proxyServices."browser.${settings.domain}" = 4848;
  services.cloudflareTunnel.proxyServices."${webuiHost}" = webuiPort;

  systemd.services.hermes-serve = {
    description = "Hermes Desktop backend (serve, no dashboard UI)";
    after = [ "hermes-agent.service" ];
    wants = [ "hermes-agent.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "hermes";
      Group = "hermes";
      Environment = [
        "HOME=${stateDir}"
        "HERMES_HOME=${stateDir}/.hermes"
      ];
      EnvironmentFile = [ "/run/hermes.env" ];
      ExecStart = "${config.services.hermes-agent.package}/bin/hermes serve --host 127.0.0.1 --port ${toString servePort} --no-open";
      Restart = "on-failure";
      RestartSec = 5;
      MemoryMax = "1G";
    };
  };
}
