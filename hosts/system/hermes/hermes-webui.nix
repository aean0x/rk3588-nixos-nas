# Hermes WebUI (nesquena/hermes-webui) — full-parity browser UI for Hermes Agent.
#
#   LAN:  Caddy archimedes.<domain> → 127.0.0.1:8787
#   WAN:  Cloudflare Tunnel → 127.0.0.1:8787   # CGNAT-safe (Starlink)
#
# Runs the agent in-process against HERMES_HOME (not OpenAI API passthrough).
# openFirewall = false; bind loopback only. Pair with tunnel/Caddy for access.
# TTS: ELEVENLABS_API_KEY via sops → /run/hermes-webui.env (+ hermes .env).
{
  settings,
  config,
  inputs,
  ...
}:
let
  port = 8787;
  domain = settings.domain;
  host = "archimedes.${domain}";
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
    # Secrets (ELEVENLABS_API_KEY). Protected runtime keys stay in module options.
    environmentFiles = [ "/run/hermes-webui.env" ];
    extraEnvironment = {
      # Behind Caddy / Cloudflare Tunnel HTTPS.
      HERMES_WEBUI_TRUST_FORWARDED_PROTO = "true";
      HERMES_WEBUI_SECURE = "true";
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
