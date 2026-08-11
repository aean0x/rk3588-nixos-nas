# RDT-Client: TorBox debrid download client with qBittorrent-compatible API.
# Used by Sonarr/Radarr (see services/arr-suite.nix).
#
#   UI  :6500  — https://rdt.<domain>
#   State: /var/lib/rdtclient
#   Downloads: /media/Videos/downloads  (mapped path for *arr import)
#
# Docs: https://github.com/rogerfar/rdt-client
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  port = 6500;
  host = "rdt.${settings.domain}";
  dataDir = "/var/lib/rdtclient";
  downloads = "/media/Videos/downloads";
  image = "rogerfar/rdtclient:latest";
  # TorBox enum value in rdt-client Provider
  providerTorBox = 3;
in
{
  sops.secrets.torbox_api_key = { };
  sops.secrets.rdtclient_password = {
    mode = "0440";
    group = "media";
  };
  sops.secrets.rdtclient_username = {
    mode = "0440";
    group = "media";
  };

  systemd.tmpfiles.rules = [
    "d ${downloads} 2775 root media - -"
    "d ${dataDir} 0750 root media - -"
  ];

  virtualisation.oci-containers.containers.rdtclient = {
    image = image;
    environment = {
      TZ = settings.timeZone;
      # media group so Sonarr/Radarr can read completed downloads
      PUID = "0";
      PGID = toString config.users.groups.media.gid;
      UMASK = "002";
    };
    volumes = [
      "${dataDir}:/data/db"
      "${downloads}:/data/downloads"
    ];
    ports = [ "${toString port}:6500" ];
    autoStart = true;
  };

  systemd.services.docker-rdtclient = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    preStart = ''
      install -d -m 0775 -o root -g media ${downloads}
      install -d -m 0750 -o root -g media ${dataDir}
    '';
  };

  # Bootstrap: create admin user, TorBox provider, download path mapping.
  # Safe to re-run (skips if user/provider already set).
  systemd.services.rdtclient-bootstrap = {
    description = "Bootstrap RDT-Client (user + TorBox + paths)";
    after = [ "docker-rdtclient.service" ];
    wants = [ "docker-rdtclient.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.curl
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
    ];
    script = ''
      set -euo pipefail
      RDT="http://127.0.0.1:${toString port}"
      USER=$(cat ${config.sops.secrets.rdtclient_username.path})
      PASS=$(cat ${config.sops.secrets.rdtclient_password.path})
      TORBOX=$(cat ${config.sops.secrets.torbox_api_key.path})

      echo "Waiting for RDT-Client..."
      for i in $(seq 1 60); do
        code=$(curl -sS -o /dev/null -w '%{http_code}' "$RDT/Api/Authentication/IsLoggedIn" || true)
        # 200=ok, 402=setup, 403=auth required
        if [ "$code" = "200" ] || [ "$code" = "402" ] || [ "$code" = "403" ]; then
          break
        fi
        sleep 2
      done

      code=$(curl -sS -o /dev/null -w '%{http_code}' "$RDT/Api/Authentication/IsLoggedIn" || true)
      if [ "$code" = "402" ]; then
        echo "Creating RDT admin user..."
        curl -sS -c /run/rdtclient.cookies -X POST "$RDT/Api/Authentication/Create" \
          -H 'Content-Type: application/json' \
          -d "{\"userName\":\"$USER\",\"password\":\"$PASS\"}"
      fi
      echo "Logging in..."
      curl -sS -c /run/rdtclient.cookies -b /run/rdtclient.cookies -X POST "$RDT/Api/Authentication/Login" \
        -H 'Content-Type: application/json' \
        -d "{\"userName\":\"$USER\",\"password\":\"$PASS\"}" >/dev/null || true

      echo "Setting TorBox provider (if empty)..."
      curl -sS -b /run/rdtclient.cookies -X POST "$RDT/Api/Authentication/SetupProvider" \
        -H 'Content-Type: application/json' \
        -d "{\"provider\":${toString providerTorBox},\"token\":\"$TORBOX\"}" \
        || true

      echo "Updating download paths + categories..."
      curl -sS -b /run/rdtclient.cookies -X PUT "$RDT/Api/Settings" \
        -H 'Content-Type: application/json' \
        -d "[
          {\"key\":\"DownloadClient:DownloadPath\",\"value\":\"/data/downloads\"},
          {\"key\":\"DownloadClient:MappedPath\",\"value\":\"${downloads}\"},
          {\"key\":\"General:Categories\",\"value\":\"sonarr,radarr\"},
          {\"key\":\"Provider:Provider\",\"value\":\"${toString providerTorBox}\"},
          {\"key\":\"Provider:ApiKey\",\"value\":\"$TORBOX\"}
        ]" || true

      rm -f /run/rdtclient.cookies
      echo "RDT-Client bootstrap done."
    '';
  };

  networking.firewall.allowedTCPPorts = [ port ];

  services.caddy.proxyServices = {
    "${host}" = port;
  };
}
