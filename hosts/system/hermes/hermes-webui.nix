# Hermes WebUI — native systemd (no docker). Reverse-proxied as
# archimedes.<domain>. Composer pairs user/package/env; this file adds
# the public edge, host remaps, and rocknas RAM caps.
{
  config,
  settings,
  hermes,
  ...
}:
let
  port = 8787;
  host = "archimedes.${settings.domain}";
in
{
  assertions = [
    {
      assertion = config.services.hermes-webui.enable;
      message = "hermes-webui must stay enabled; it is the interactive surface.";
    }
    {
      assertion = config.services.hermesPnP.pluginInstall.webuiExtensionDir != null;
      message = "hermes-webui needs hermesPnP model-router plugin for HERMES_WEBUI_EXTENSION_DIR.";
    }
  ];

  services.hermes-webui = {
    enable = true;
    host = "127.0.0.1";
    inherit port;
    openFirewall = false;
    extraEnvironment = config.services.hermes-agent.environment // {
      HERMES_WEBUI_TRUST_FORWARDED_PROTO = "true";
      HERMES_WEBUI_SECURE = "true";
      HERMES_WEBUI_EXTENSION_DIR = toString config.services.hermesPnP.pluginInstall.webuiExtensionDir;
      HERMES_WEBUI_EXTENSION_MANIFEST = "extensions.json";
      HERMES_MEMORY_REGISTRY = hermes.memoryRegistry.host;
      GBRAIN_AUDIT_DIR = hermes.gbrainAudit.host;
      PATH = config.services.hermesPnP.toolbox.hostPath;
    };
  };

  systemd.services.hermes-webui.serviceConfig = hermes.systemdResourceConfig;

  services.caddy.proxyServices."${host}" = port;
  services.cloudflareTunnel.proxyServices."${host}" = port;
}
