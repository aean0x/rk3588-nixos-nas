# Hermes WebUI (nesquena/hermes-webui) — full-parity browser UI.
#
#   LAN:  Caddy archimedes.<domain> → 127.0.0.1:8787
#   WAN:  Cloudflare Tunnel → 127.0.0.1:8787   # CGNAT-safe (Starlink)
#
# Native systemd (not a second Docker container). In-process agent against
# HERMES_HOME. Package + hermesRuntimeEnv + resource caps come from the same
# maps as the gateway (runtime.nix + overrides/package-fix.nix).
#
# openFirewall = false; bind loopback only. Pair with tunnel/Caddy for access.
{
  settings,
  config,
  inputs,
  hermes,
  hermesRuntimeEnv ? { },
  ...
}:
let
  port = 8787;
  domain = settings.domain;
  host = "archimedes.${domain}";
  agentPkg = config.services.hermes-agent.package;
in
{
  imports = [ inputs.hermes-webui.nixosModules.default ];

  # Pairing: same drv + store-env as the gateway. Do not .override extras here.
  assertions = [
    {
      assertion = hermesRuntimeEnv != { };
      message = "hermes-webui requires overrides/package-fix.nix hermesRuntimeEnv.";
    }
    {
      assertion = config.services.hermes-webui.agent.package == agentPkg;
      message = "hermes-webui.agent.package must be services.hermes-agent.package (no extra override).";
    }
  ];

  services.hermes-webui = {
    enable = true;
    host = "127.0.0.1";
    inherit port;
    openFirewall = false;
    stateDir = "/var/lib/hermes-webui";
    user = "hermes";
    group = "hermes";
    hermesHome = hermes.hermesHome;
    # Derives HERMES_WEBUI_PYTHON from passthru.hermesVenv on the shared package.
    agent.package = agentPkg;
    environmentFiles = config.services.hermes-agent.environmentFiles;
    extraEnvironment = hermesRuntimeEnv // {
      HERMES_WEBUI_TRUST_FORWARDED_PROTO = "true";
      HERMES_WEBUI_SECURE = "true";
      HERMES_WEBUI_EXTENSION_DIR = "${./integrations/plugins/model-router/webui}";
      HERMES_WEBUI_EXTENSION_MANIFEST = "extensions.json";
      # Host remaps of container-only paths (gateway sees /data and /home/hermes).
      HERMES_MEMORY_REGISTRY = hermes.memoryRegistry.host;
      GBRAIN_AUDIT_DIR = hermes.gbrainAudit.host;
      PATH = hermes.hostPath;
    };
  };

  systemd.services.hermes-webui = {
    after = [
      "network-online.target"
      "hermes-agent.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = hermes.systemdResourceConfig;
  };

  services.caddy.proxyServices."${host}" = port;
  services.cloudflareTunnel.proxyServices."${host}" = port;
}
