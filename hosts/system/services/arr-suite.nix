# Nixarr: Sonarr + Radarr, library under /media/Videos, download client = RDT-Client.
#
# Paths:
#   /media/Videos/library/movies  → bind of Movies
#   /media/Videos/library/shows   → bind of Shows
#   /media/Videos/downloads       → RDT-Client (containers/rdtclient.nix)
#
# UIs (LAN):
#   https://sonarr.<domain>  :8989
#   https://radarr.<domain>  :7878
#   https://rdt.<domain>     :6500  (see containers/rdtclient.nix)
#
# RDT container + TorBox bootstrap live in hosts/system/containers/rdtclient.nix.
# Docs: hosts/system/services/ARR.md
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  videos = "/media/Videos";
  mediaDir = videos;
  stateDir = "/var/lib/nixarr";
  rdtPort = 6500;
  sonarrPort = 8989;
  radarrPort = 7878;
  domain = settings.domain;
in
{
  # Password shared with RDT bootstrap / Sonarr·Radarr qBittorrent client
  # (declared with mode in containers/rdtclient.nix; ensure both modules load).
  sops.secrets.rdtclient_password = {
    mode = "0440";
    group = "media";
  };

  # ---- library layout: keep user's Movies/Shows, expose nixarr paths -------
  systemd.tmpfiles.rules = [
    "d ${videos} 2775 root media - -"
    "d ${videos}/Movies 2775 root media - -"
    "d ${videos}/Shows 2775 root media - -"
    "d ${videos}/library 2775 root media - -"
  ];

  fileSystems."${videos}/library/movies" = {
    device = "${videos}/Movies";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
  };
  fileSystems."${videos}/library/shows" = {
    device = "${videos}/Shows";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
  };

  # ---- nixarr: Sonarr + Radarr ---------------------------------------------
  nixarr = {
    enable = true;
    mediaDir = mediaDir;
    stateDir = stateDir;
    mediaUsers = [ settings.adminUser ];

    sonarr = {
      enable = true;
      openFirewall = true;
      settings-sync = {
        downloadClients = [
          {
            name = "RDT-Client";
            implementation = "QBittorrent";
            enable = true;
            fields = {
              host = "127.0.0.1";
              port = rdtPort;
              useSsl = false;
              username = "admin";
              password.secret = config.sops.secrets.rdtclient_password.path;
              tvCategory = "sonarr";
            };
          }
        ];
      };
    };

    radarr = {
      enable = true;
      openFirewall = true;
      settings-sync = {
        downloadClients = [
          {
            name = "RDT-Client";
            implementation = "QBittorrent";
            enable = true;
            fields = {
              host = "127.0.0.1";
              port = rdtPort;
              useSsl = false;
              username = "admin";
              password.secret = config.sops.secrets.rdtclient_password.path;
              movieCategory = "radarr";
            };
          }
        ];
      };
    };
  };

  # Local API for settings-sync (and LAN convenience)
  services.sonarr.settings.auth.required = "DisabledForLocalAddresses";
  services.radarr.settings.auth.required = "DisabledForLocalAddresses";

  # Wire *arr settings-sync after RDT is bootstrapped
  systemd.services.sonarr-sync-config = {
    after = [ "rdtclient-bootstrap.service" ];
    wants = [ "rdtclient-bootstrap.service" ];
  };
  systemd.services.radarr-sync-config = {
    after = [ "rdtclient-bootstrap.service" ];
    wants = [ "rdtclient-bootstrap.service" ];
  };

  # Root folders via Arr API (idempotent). Wait for *arr API + config.xml.
  systemd.services.arr-rootfolders = {
    description = "Ensure Sonarr/Radarr root folders for Videos library";
    after = [
      "sonarr.service"
      "radarr.service"
      "sonarr-api.service"
      "radarr-api.service"
    ];
    wants = [
      "sonarr.service"
      "radarr.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.curl
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.libxml2
    ];
    script = ''
      set -euo pipefail
      get_key() {
        local cfg="$1"
        for _ in $(seq 1 60); do
          if [ -f "$cfg" ]; then
            key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" || true)
            if [ -n "''${key:-}" ]; then
              echo "$key"
              return 0
            fi
          fi
          sleep 2
        done
        return 1
      }
      wait_api() {
        local url="$1" key="$2"
        for i in $(seq 1 60); do
          if curl -sf -H "X-Api-Key: $key" "$url/api/v3/system/status" >/dev/null; then
            return 0
          fi
          sleep 2
        done
        return 1
      }
      ensure_root() {
        local base="$1" key="$2" path="$3"
        existing=$(curl -sf -H "X-Api-Key: $key" "$base/api/v3/rootfolder" || echo '[]')
        if echo "$existing" | grep -Fq "$path"; then
          echo "Root folder already present: $path"
          return 0
        fi
        curl -sf -X POST -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
          -d "{\"path\":\"$path\"}" \
          "$base/api/v3/rootfolder" >/dev/null \
          && echo "Added root folder: $path" \
          || echo "WARN: could not add root folder $path (add in UI if needed)"
      }

      if SKEY=$(get_key ${stateDir}/sonarr/config.xml); then
        wait_api "http://127.0.0.1:${toString sonarrPort}" "$SKEY" || true
        ensure_root "http://127.0.0.1:${toString sonarrPort}" "$SKEY" "${videos}/library/shows"
      else
        echo "Sonarr API key not ready yet"
      fi
      if RKEY=$(get_key ${stateDir}/radarr/config.xml); then
        wait_api "http://127.0.0.1:${toString radarrPort}" "$RKEY" || true
        ensure_root "http://127.0.0.1:${toString radarrPort}" "$RKEY" "${videos}/library/movies"
      else
        echo "Radarr API key not ready yet"
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [
    sonarrPort
    radarrPort
  ];

  services.caddy.proxyServices = {
    "sonarr.${domain}" = sonarrPort;
    "radarr.${domain}" = radarrPort;
  };
}
