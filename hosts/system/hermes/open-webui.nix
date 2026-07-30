# Open WebUI — polished chat frontend for Hermes Agent.
#
# Architecture (loopback-only Hermes API; Caddy terminates TLS/LAN):
#   Browser → Caddy open-webui.<domain> (LAN-only like hermes dashboard)
#          → services.open-webui 127.0.0.1:8080
#          → Hermes gateway API  http://127.0.0.1:8642/v1
#
# Port 8080: free of AdGuard (:3000), FileBrowser (:8085), Hermes dashboard (:9119).
# openFirewall = false — only Caddy faces LAN/Tailscale.
# Do NOT set API_SERVER_HOST=0.0.0.0; API stays on loopback.
{ lib, settings, ... }:
let
  # Native open-webui default; documented in workspace/OPEN-WEBUI.md.
  port = 8080;
  domain = settings.domain;
in
{
  # nixpkgs marks open-webui unfree (Open WebUI License) as of 0.11.x.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  # Hermes OpenAI-compatible API server (first-class, durable via HERMES_MANAGED
  # /run/hermes.env — not `hermes config set`). Non-secret knobs here so the
  # gateway process always sees them even if dotenv merge order drifts.
  services.hermes-agent.environment = {
    API_SERVER_ENABLED = "true";
    API_SERVER_HOST = "127.0.0.1";
    API_SERVER_PORT = "8642";
    API_SERVER_MODEL_NAME = "hermes-agent";
  };

  # Also inject into the container process env (dotenv alone is not always
  # visible to all gateway children; same pattern as browser.nix CDP).
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

  services.open-webui = {
    enable = true;
    host = "127.0.0.1";
    inherit port;
    openFirewall = false;
    # OPENAI_API_KEY from sops template (same value as Hermes API_SERVER_KEY).
    environmentFile = "/run/open-webui.env";
    environment = {
      ENABLE_OLLAMA_API = "false";
      OPENAI_API_BASE_URL = "http://127.0.0.1:8642/v1";
      SCARF_NO_ANALYTICS = "True";
      DO_NOT_TRACK = "True";
      ANONYMIZED_TELEMETRY = "False";
      # First registered user becomes admin.
      WEBUI_AUTH = "true";
      # Reverse-proxy public URL (overrides module localhost default).
      WEBUI_URL = "https://open-webui.${domain}";
    };
  };

  systemd.services.open-webui = {
    after = [
      "network-online.target"
      "hermes-agent.service"
    ];
    wants = [ "network-online.target" ];
    # Soft dependency: UI can start if gateway is restarting; models fail until API is up.
  };

  # LAN-only by default (not in caddy.externalHosts) — same as hermes dashboard.
  services.caddy.proxyServices."open-webui.${domain}" = port;
}
