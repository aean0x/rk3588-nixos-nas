# Open WebUI — polished chat frontend for Hermes Agent.
#
#   LAN:  Caddy open-webui.<domain> → 127.0.0.1:8080
#   WAN:  Cloudflare Tunnel (proxyServices) → 127.0.0.1:8080   # CGNAT-safe
#         → Hermes API http://127.0.0.1:8642/v1 (loopback only)
#
# Port 8080: free of AdGuard (:3000), FileBrowser (:8085), Hermes dashboard (:9119).
# openFirewall = false. Do NOT bind API_SERVER_HOST=0.0.0.0.
# Auth (WEBUI_AUTH) on — first registered user is admin.
{ lib, settings, ... }:
let
  # Native open-webui default; documented in workspace/OPEN-WEBUI.md.
  port = 8080;
  domain = settings.domain;
  host = "open-webui.${domain}";
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
      WEBUI_URL = "https://${host}";
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

  # LAN via Caddy; public via Cloudflare Tunnel (declare both like other dual-path apps).
  services.caddy.proxyServices."${host}" = port;
  services.cloudflareTunnel.proxyServices."${host}" = port;
}
