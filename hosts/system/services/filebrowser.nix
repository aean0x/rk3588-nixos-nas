# FileBrowser: Web-based file manager
{
  config,
  pkgs,
  settings,
  ...
}:
let
  port = 8085;
  image = "filebrowser/filebrowser:latest";
  dataDir = "/var/lib/filebrowser";

  # Folders to expose
  openclawDir = "/var/lib/openclaw";
in
{
  # ===================
  # Containers
  # ===================
  virtualisation.oci-containers.containers = {
    filebrowser = {
      image = image;
      environment = {
        FB_PORT = "80";
        FB_ADDRESS = "0.0.0.0";
        FB_DATABASE = "/database/filebrowser.db";
        FB_ROOT = "/srv";
        FB_LOG = "stdout";
        FB_NOAUTH = "false";
      };
      volumes = [
        "${dataDir}:/database"
        "${dataDir}/config:/config"
        "${openclawDir}:/srv/openclaw:rw"
        # Add more folders here later, e.g.:
        # "/media:/srv/media:rw"
      ];
      ports = [
        "${toString port}:80"
      ];
      # Run as same user as OpenClaw (1000) to ensure read/write access
      user = "1000:1000";
      autoStart = true;
    };
  };

  # ===================
  # Pre-start setup
  # ===================
  systemd.services.docker-filebrowser.preStart = ''
    mkdir -p ${dataDir}/config
    chown -R 1000:1000 ${dataDir}
    chmod -R 700 ${dataDir}
  '';

  # ===================
  # Firewall
  # ===================
  networking.firewall.allowedTCPPorts = [ port ];

  # ===================
  # Reverse Proxy
  # ===================
  services.caddy.proxyServices = {
    "files.${settings.domain}" = port;
  };
}
