# Comet: Stremio addon (debrid/torrent streams, TorBox-first)
# Uses g0ldyy/comet. Lightweight sqlite setup. Public HTTPS via Caddy.
# Enable by uncommenting the import in containers.nix.
{
  config,
  settings,
  ...
}:
let
  port = 8000;
  host = "comet.${settings.domain}";
  dataDir = "/var/lib/comet";
  image = "g0ldyy/comet:latest";
in
{
  # Required when Comet is enabled (the secret is only declared for this optional module)
  sops.secrets.torbox_api_key = { };

  # ===================
  # Container
  # ===================
  virtualisation.oci-containers.containers.comet = {
    image = image;
    environment = {
      TZ = settings.timeZone;

      # Lightweight single-container setup
      DATABASE_TYPE = "sqlite";
      DATABASE_PATH = "/app/data/comet.db";

      # Public URL used in generated links/manifests (affects Stremio install URLs)
      PUBLIC_BASE_URL = "https://${host}";

      # Keep configuration endpoint directly accessible (no password)
      CONFIGURE_PAGE_PASSWORD = "";

      # TorBox-first defaults; can be changed for other providers (Real-Debrid, etc.)
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

  # ===================
  # Pre-start: inject SOPS secret(s) into env file for the container
  # (runs before docker-comet.service)
  # ===================
  systemd.services.docker-comet.preStart = ''
    install -d -m 0750 ${dataDir}

    {
      echo "TORBOX_API_KEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
      echo "DEBRIDIO_PROVIDER_KEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
      echo "PROXY_DEBRID_STREAM_DEBRID_DEFAULT_APIKEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
    } > /run/comet.env

    chmod 0600 /run/comet.env
  '';

  # ===================
  # Firewall (direct host port + Caddy terminates TLS)
  # ===================
  networking.firewall.allowedTCPPorts = [ port ];

  # ===================
  # Reverse Proxy
  # Caddy vhost at comet.<domain>. Marked external so it's reachable from WAN
  # (Stremio clients on phones etc. need to fetch the manifest and streams).
  # ===================
  services.caddy.proxyServices = {
    "${host}" = port;
  };

  services.caddy.externalHosts = [ host ];
}
