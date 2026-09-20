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

    # Single primary: models.default seeds session, cron, and delegation.
    # modelPicker.enable = false strips the plugin even if listed, sets
    # context.engine = compressor, and would copy models.default into
    # fallback_model — override that on hermes-agent.settings below.
    modelPicker.enable = false;
    models.default = {
      provider = "deepseek";
      model = "deepseek-flash";
    };
    models.auxiliary = {
      provider = "deepseek";
      model = "deepseek-flash";
    };

    plugins = [
      "tool-call-coherency"
      "secret-handoff"
      "git-hook"
      # One session at a time on the shared CDP engine. Without this, each
      # concurrent WebUI/cron/kanban browser turn adds its own tab set and
      # the 1g cage OOM-kills Brave (hermes-pnp #103).
      "browser-lease"
    ];

    toolbox.extraPackages = [ pkgs.sops ];

    mcpProxy.enable = true;
    hmc.enable = true;
    gbrain.enable = true;
    # Pin matches the 2026-09-16 re-embed (ZeroEntropy zembed-1 @2560 →
    # Voyage-4 @1024). Env override wins at query time, so this must not
    # land against a still-2560 column. File plane is ~/.gbrain/config.json.
    gbrain.embeddingModel = "openrouter:voyageai/voyage-4";
    gbrain.embeddingDimensions = 1024;
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

      # Preference: 8 GiB jail. Upstream default is 10.
      delegation.max_concurrent_children = 5;

      # Absolute compaction cap for every model; the composer seeds per-model
      # ratios (`models.<name>.compression_ratio` -> `model_thresholds`) but a
      # ratio cannot express this one. The fallback (grok-4.6) has a 500k
      # window, under Hermes' 512k small-context floor, so its ratio is raised
      # to >= 0.75 -> a 375k trigger; xAI doubles every rate for the whole
      # request once a prompt reaches 200k tokens, so the cap is the only knob
      # that holds the fallback under the cliff (200000 / 500000 = 0.40, below
      # the floor a ratio can reach). It also holds the primary at 200k: its
      # 0.26 ratio alone resolves to 260k on the 1M window.
      compression.threshold_tokens = 200000;

      # Kanban dispatch spawns one worker process per card (~240 MiB resident
      # each). The dispatcher's memory-derived cap reads the HOST's MemTotal
      # (7642 MiB / 512 MiB per worker, clamped to 8), so the cap has to be held
      # down here as well: at --memory=1g two workers alone reached the cgroup
      # ceiling with swap disabled, and the memcg then throttles TCP socket
      # buffers, so every MCP client at once (gbrain, banksync,
      # composio, robinhood, policylayer) missed its 30 s keepalive deadline.
      # The jail cap is 2g in runtime.nix (2026-09-20), and the cron side keeps
      # one agent in the 06:00-07:00 window
      # (skill feng-scheduled-ops -> references/cron-job-catalog.md).
      kanban.max_in_progress = 2;

      # A card created from a gateway session otherwise auto-subscribes the
      # originating chat, so every routine completion wakes a chat session.
      # Silent is the default; subscribe a card explicitly when a ping carries
      # information.
      kanban.auto_subscribe_on_create = false;

      cron.wrap_response = false;

      # Interim, revocable. Upstream's bounded-hook latch drops a healthy
      # concurrent callback ("skipped after previous timeout or while still
      # running"): one (hook, callback) bit covers both a real timeout and
      # ordinary overlap, so parallel tool batches lose hook work while the log
      # records zero timeouts (#98382 canonical, #104865 duplicate; #105223 is
      # the same latch permanently fail-closing pre_tool_call). <= 0 disables
      # the threaded path, so hooks run in the caller and nothing is dropped.
      # Every hook in this profile is self-bounded: git-hook subprocesses carry
      # GIT_HOOK_* timeouts, the gbrain hooks are local IO or urllib with a
      # socket timeout. Delete this line once the pinned hermes-agent carries
      # the upstream fix (staged: #98385, #104763).
      plugins.hook_callback_timeout = 0;

      security = {
        allow_lazy_installs = false;
        allow_private_urls = true;
      };

      web = {
        search_backend = "xai";
        extract_backend = "firecrawl";
      };

      timezone = settings.timeZone;

      # Upstream fallback. PnP would seed models.default (flash) here
      # with the router off; last writer wins (do not mkDefault).
      fallback_model = {
        provider = "xai-oauth";
        model = "grok-4.6";
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

  # WebUI: LAN Caddy + Cloudflare Tunnel. hermes.<domain> is a LAN/Tailscale
  # alias to the same WebUI (no extra backend). Browser gate: LAN/Tailscale,
  # no tunnel.
  # Do not set hermesPnP.desktop.enable: it mkForces the agent jail off
  # and asserts container.enable is false. Official `hermes serve` /
  # backend.mode cannot run beside the jail — host `hermes` is a docker
  # CLI router, and the gateway already lives in hermes-agent.
  services.caddy.proxyServices."${webuiHost}" = webuiPort;
  services.caddy.proxyServices."hermes.${settings.domain}" = webuiPort;
  services.caddy.proxyServices."browser.${settings.domain}" = 4848;
  services.cloudflareTunnel.proxyServices."${webuiHost}" = webuiPort;
}
