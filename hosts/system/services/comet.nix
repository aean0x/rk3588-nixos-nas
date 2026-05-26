# Comet (Stremio addon replacement for TorBox) via Docker
{
  config,
  settings,
  ...
}:
let
  port = 8000;
  host = "comet.${settings.domain}";
  dataDir = "/var/lib/comet";
in
{
  # Required when Comet is enabled
  sops.secrets.torbox_api_key = { };

  virtualisation.oci-containers.containers.comet = {
    image = "g0ldyy/comet:latest";
    environment = {
      TZ = settings.timeZone;

      # Lightweight single-container setup
      DATABASE_TYPE = "sqlite";
      DATABASE_PATH = "/app/data/comet.db";

      # Public URL used in generated links/manifests
      PUBLIC_BASE_URL = "https://${host}";

      # Keep configuration endpoint directly accessible
      CONFIGURE_PAGE_PASSWORD = "";

      # TorBox-first defaults; can be changed for other providers
      SCRAPE_TORBOX = "True";
      SCRAPE_DEBRIDIO = "False";
      DEBRIDIO_PROVIDER = "torbox";
      PROXY_DEBRID_STREAM = "False";
      PROXY_DEBRID_STREAM_DEBRID_DEFAULT_SERVICE = "torbox";
    };
    environmentFiles = [ "/run/comet.env" ];
    volumes = [ "${dataDir}:/app/data" ];
    networks = [ "host" ];
    autoStart = true;
  };

  systemd.services.docker-comet.preStart = ''
    install -d -m 0750 ${dataDir}

    {
      echo "TORBOX_API_KEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
      echo "DEBRIDIO_PROVIDER_KEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
      echo "PROXY_DEBRID_STREAM_DEBRID_DEFAULT_APIKEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
    } > /run/comet.env

    chmod 0600 /run/comet.env
  '';

  networking.firewall.allowedTCPPorts = [ port ];

  services.caddy.proxyServices = {
    "${host}" = port;
  };

  # Allow WAN access so Stremio clients can reach /configure and addon endpoints.
  services.caddy.externalHosts = [ host ];
}
