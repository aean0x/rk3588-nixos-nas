# Hermes WebUI — native systemd (no docker). Reverse-proxied as
# archimedes.<domain>. Same agent identity as the gateway: composer
# pairs user/package/env; this file adds the public edge + remaps.
{
  config,
  lib,
  settings,
  hermes,
  ...
}: {
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
    port = 8787;
    openFirewall = false;
    extraEnvironment =
      config.services.hermes-agent.environment
      // {
        HERMES_WEBUI_TRUST_FORWARDED_PROTO = "1";
        HERMES_WEBUI_SECURE = "1";
        HERMES_WEBUI_EXTENSION_DIR = toString config.services.hermesPnP.pluginInstall.webuiExtensionDir;
        HERMES_WEBUI_EXTENSION_MANIFEST = "extensions.json";
        HERMES_MEMORY_REGISTRY = hermes.memoryRegistry.container;
        GBRAIN_AUDIT_DIR = hermes.gbrainAudit.container;
        PATH = config.services.hermesPnP.toolbox.hostPath;
      };
  };

  systemd.services.hermes-webui.serviceConfig = {
    MemoryMax = hermes.resources.memory;
    MemoryHigh = hermes.resources.memory;
    MemorySwapMax = "0";
    TasksMax = 512;
    LimitNOFILE = 65535;
    OOMPolicy = "continue";
  };

  services.caddy.virtualHosts."archimedes.${settings.domain}".extraConfig = ''
    encode gzip
    reverse_proxy 127.0.0.1:8787
  '';

  services.cloudflared.tunnels.${settings.cloudflareTunnelId}.ingress = {
    "archimedes.${settings.domain}" = "http://127.0.0.1:8787";
  };
}
