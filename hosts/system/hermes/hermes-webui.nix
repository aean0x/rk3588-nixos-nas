# Hermes WebUI (nesquena/hermes-webui) — full-parity browser UI for Hermes Agent.
#
#   LAN:  Caddy archimedes.<domain> → 127.0.0.1:8787
#   WAN:  Cloudflare Tunnel → 127.0.0.1:8787   # CGNAT-safe (Starlink)
#
# Runs the agent in-process against HERMES_HOME (not OpenAI API passthrough).
# openFirewall = false; bind loopback only. Pair with tunnel/Caddy for access.
# TTS: ELEVENLABS_API_KEY via sops → /run/hermes-webui.env (+ hermes .env).
#
# Packaging contract: WebUI never execs $package/bin/hermes (the makeWrapper
# that sets HERMES_BUNDLED_*). Inject the same map from package-fix.nix so
# in-process agent matches the gateway.
{
  settings,
  config,
  inputs,
  hermesPackageDataEnv ? { },
  ...
}:
let
  port = 8787;
  domain = settings.domain;
  host = "archimedes.${domain}";
  # Fallback if package-fix not loaded: derive from agent package (same layout).
  pkg = config.services.hermes-agent.package;
  share = "${pkg}/share/hermes-agent";
  bundledEnv =
    if hermesPackageDataEnv != { } then
      hermesPackageDataEnv
    else
      {
        HERMES_BUNDLED_PLUGINS = "${share}/plugins";
        HERMES_BUNDLED_SKILLS = "${share}/skills";
        HERMES_OPTIONAL_SKILLS = "${share}/optional-skills";
        HERMES_BUNDLED_LOCALES = "${share}/locales";
        HERMES_OPTIONAL_MCPS = "${share}/optional-mcps";
        HERMES_WEB_DIST = "${share}/web_dist";
        HERMES_TUI_DIR = "${pkg}/ui-tui";
      };
in
{
  imports = [ inputs.hermes-webui.nixosModules.default ];

  # Hermes OpenAI-compatible API server kept for loopback clients (tools, scripts).
  # Not used by WebUI chat (in-process agent); still useful independently.
  services.hermes-agent.environment = {
    API_SERVER_ENABLED = "true";
    API_SERVER_HOST = "127.0.0.1";
    API_SERVER_PORT = "8642";
    API_SERVER_MODEL_NAME = "hermes-agent";
  };

  services.hermes-agent.container.extraOptions = [
    "--env"
    "API_SERVER_ENABLED=true"
    "--env"
    "API_SERVER_HOST=127.0.0.1"
    "--env"
    "API_SERVER_PORT=8642"
    "--env"
    "API_SERVER_MODEL_NAME=hermes-agent"
  ];

  services.hermes-webui = {
    enable = true;
    host = "127.0.0.1";
    inherit port;
    openFirewall = false;
    stateDir = "/var/lib/hermes-webui";
    # Share the agent service account so HERMES_HOME is readable/writable.
    user = "hermes";
    group = "hermes";
    hermesHome = "${config.services.hermes-agent.stateDir}/.hermes";
    # Derives HERMES_WEBUI_PYTHON from passthru.hermesVenv on the sealed package.
    agent.package = config.services.hermes-agent.package;
    # Full agent secrets first (BRAVE/XAI/X_*/FIRECRAWL/…), then WebUI-only
    # overlay (ELEVENLABS). WebUI runs an *in-process* second agent against the
    # same HERMES_HOME — without hermes.env it only had TTS and looked
    # "unconfigured" for search even when gateway/.env were fine.
    environmentFiles = [
      "/run/hermes.env"
      "/run/hermes-webui.env"
    ];
    extraEnvironment = bundledEnv // {
      # Behind Caddy / Cloudflare Tunnel HTTPS.
      HERMES_WEBUI_TRUST_FORWARDED_PROTO = "true";
      HERMES_WEBUI_SECURE = "true";
      # Official WebUI extension sidecar (no core/static patches).
      # Store path is read-only and exists before the unit starts.
      HERMES_WEBUI_EXTENSION_DIR = "${./plugins/model-router/webui}";
      HERMES_WEBUI_EXTENSION_MANIFEST = "extensions.json";
    };
  };

  systemd.services.hermes-webui = {
    after = [
      "network-online.target"
      "hermes-agent.service"
    ];
    wants = [ "network-online.target" ];
  };

  # LAN via Caddy; public via Cloudflare Tunnel (same dual-path pattern as before).
  services.caddy.proxyServices."${host}" = port;
  services.cloudflareTunnel.proxyServices."${host}" = port;
}
