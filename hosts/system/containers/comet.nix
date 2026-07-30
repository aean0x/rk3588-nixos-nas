# Comet: Stremio addon (debrid/torrent streams)
# Uses g0ldyy/comet + dedicated PostgreSQL (matches upstream deployment/docker-compose.yml).
# Public HTTPS via Caddy. Enable by uncommenting the import in containers.nix.
{
  config,
  lib,
  settings,
  ...
}:
let
  port = 8000;
  host = "comet.${settings.domain}";
  cometDataDir = "/var/lib/comet";
  postgresDataDir = "/var/lib/comet-postgres";
  # postgres user inside the official postgres:*-alpine images (uid/gid used for the process and file ownership)
  postgresUid = 999;
  cometImage = "g0ldyy/comet:latest";
  postgresImage = "postgres:18-alpine";
in
{
  # Required when Comet is enabled (the secrets are only declared for this optional module).
  # Add the values via secrets workflow before uncommenting the import.
  sops.secrets = {
    torbox_api_key = { };
    comet_admin_dashboard_password = { };
  };

  # ===================
  # Containers (comet + postgres backend)
  # ===================
  virtualisation.oci-containers.containers = {
    # PostgreSQL for Comet (production DB; SQLite is dev-only per upstream).
    comet-postgres = {
      image = postgresImage;
      environment = {
        POSTGRES_USER = "comet";
        POSTGRES_PASSWORD = "comet";
        POSTGRES_DB = "comet";
        TZ = settings.timeZone;
        # Mount the persistent dir directly at PGDATA. This lets the container's
        # rootfs (writable) handle any top-level mkdirs the entrypoint does
        # (e.g. versioned dirs), while the data itself is the bind mount.
        PGDATA = "/var/lib/postgresql/data";
      };
      volumes = [
        "${postgresDataDir}:/var/lib/postgresql/data"
      ];
      cmd = [
        "postgres"
        "-c"
        "shared_buffers=128MB"
        "-c"
        "effective_cache_size=384MB"
        "-c"
        "maintenance_work_mem=64MB"
        "-c"
        "checkpoint_completion_target=0.9"
        "-c"
        "wal_buffers=8MB"
        "-c"
        "random_page_cost=1.1"
        "-c"
        "effective_io_concurrency=200"
        "-c"
        "work_mem=8MB"
        "-c"
        "max_connections=100"
      ];
      extraOptions = [
        # Healthcheck (mirrors upstream compose)
        "--health-cmd"
        "pg_isready -U comet -d comet"
        "--health-interval=5s"
        "--health-timeout=5s"
        "--health-retries=5"
      ];
      networks = [ "host" ];
      autoStart = true;
    };

    # Comet application
    comet = {
      image = cometImage;
      environment = {
        TZ = settings.timeZone;

        # PostgreSQL (production)
        DATABASE_TYPE = "postgresql";
        DATABASE_URL = "comet:comet@127.0.0.1:5432/comet";

        # Public URL used in generated links/manifests (affects Stremio install URLs)
        PUBLIC_BASE_URL = "https://${host}";

        # TorBox-first defaults; edit here for other providers (Real-Debrid, etc.)
        SCRAPE_TORBOX = "True";
        SCRAPE_DEBRIDIO = "False";
        DEBRIDIO_PROVIDER = "torbox";
        PROXY_DEBRID_STREAM = "False";
        PROXY_DEBRID_STREAM_DEBRID_DEFAULT_SERVICE = "torbox";
      };
      environmentFiles = [ "/run/comet.env" ];
      volumes = [
        "${cometDataDir}:/app/data"
      ];
      extraOptions = [
        # Healthcheck (mirrors upstream compose)
        "--health-cmd"
        "wget -qO- http://127.0.0.1:8000/health"
        "--health-interval=5s"
        "--health-timeout=5s"
        "--health-retries=5"
        "--health-start-period=10s"
      ];
      networks = [ "host" ];
      autoStart = true;
    };
  };

  # ===================
  # Service ordering + pre-start setup
  # ===================
  systemd.services."docker-comet-postgres" = {
    preStart = ''
      # Aggressively ensure the bind mount dir is writable by the postgres uid (999)
      # and by root (for entrypoint init). The postgres:18-alpine entrypoint does
      # mkdir/initdb (sometimes under the service uid) before dropping privileges.
      mkdir -p ${postgresDataDir}
      chown ${toString postgresUid}:${toString postgresUid} ${postgresDataDir} || true
      chmod 777 ${postgresDataDir}
    '';

    # The postgres unit can flap on first init (mkdir + initdb); give it breathing room.
    serviceConfig = {
      StartLimitBurst = lib.mkForce 20;
      StartLimitIntervalSec = lib.mkForce "10min";
    };
  };

  systemd.services.docker-comet = {
    after = [ "docker-comet-postgres.service" ];
    wants = [ "docker-comet-postgres.service" ];

    preStart = ''
      install -d -m 0750 ${cometDataDir}

      # Inject SOPS secrets (ADMIN is required before public exposure).
      {
        echo "ADMIN_DASHBOARD_PASSWORD=$(cat ${config.sops.secrets.comet_admin_dashboard_password.path})"
        echo "TORBOX_API_KEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
        echo "DEBRIDIO_PROVIDER_KEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
        echo "PROXY_DEBRID_STREAM_DEBRID_DEFAULT_APIKEY=$(cat ${config.sops.secrets.torbox_api_key.path})"
      } > /run/comet.env

      chmod 0600 /run/comet.env

      # Wait for postgres (on host net) to be listening before starting comet.
      # The app does not retry the initial DB connect reliably on boot.
      echo "Waiting for postgres on 127.0.0.1:5432..."
      for i in $(seq 1 60); do
        if timeout 1 bash -c 'echo > /dev/tcp/127.0.0.1/5432' >/dev/null 2>&1; then
          echo "Postgres is up."
          break
        fi
        sleep 2
      done
    '';
  };

  # ===================
  # Firewall (only the app port; postgres stays internal via host net + no firewall rule)
  # ===================
  networking.firewall.allowedTCPPorts = [ port ];

  # ===================
  # Reverse Proxy
  # Caddy vhost at comet.<domain>. LAN-only (not in caddy.externalHosts).
  # ===================
  services.caddy.proxyServices = {
    "${host}" = port;
  };
}
