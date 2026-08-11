# ErsatzTV: custom live IPTV channels from local media under /media/Videos.
# UI :8409 — M3U at /iptv/channels.m3u — LAN Caddy tv.<domain>
# Docs: https://ersatztv.org/docs/installation/docker
#
# Local media: host /media/Videos → container /media/library
#   (matches LibraryPath already in ersatztv.sqlite3).
# Seed demo music-video channels: scripts/oneshot/ersatztv-seed-music.sh
#
# Transcode (mainline kernel — no usable H.264 Rkmpp/V4L2 encode):
#   Lean software profile in SQLite: 480p + libx264 ultrafast + ThreadCount=2.
#   See IPTV.md.
{
  config,
  lib,
  settings,
  ...
}:
let
  port = 8409;
  host = "tv.${settings.domain}";
  dataDir = "/var/lib/ersatztv";
  videosMount = "/media/Videos";
  image = "ghcr.io/ersatztv/legacy:latest";
in
{
  virtualisation.oci-containers.containers.ersatztv = {
    image = image;
    environment = {
      TZ = settings.timeZone;
    };
    volumes = [
      "${dataDir}:/config"
      # Local libraries (Music Videos, Movies, Shows).
      "${videosMount}:/media/library:ro"
    ];
    extraOptions = [
      # Keep transcodes off disk (RAM tmpfs); smaller now that we only soft-encode.
      "--tmpfs=/transcode:rw,noexec,nosuid,size=1g"
    ];
    networks = [ "host" ];
    autoStart = true;
  };

  systemd.services.docker-ersatztv = {
    preStart = ''
      install -d -m 0755 ${dataDir}
    '';
  };

  networking.firewall.allowedTCPPorts = [ port ];

  # LAN-only HTTPS (not in caddy.externalHosts). IPTV clients can also use
  # plain http://192.168.1.200:8409 which is often more reliable on smart TVs.
  services.caddy.proxyServices = {
    "${host}" = port;
  };
}
