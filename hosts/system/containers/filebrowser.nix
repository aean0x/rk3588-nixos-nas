# FileBrowser: Web-based file manager
{
  config,
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
        # Secret mounted from pre-start copy
        "${dataDir}/admin_password:/run/secrets/admin_password:ro"
      ];
      ports = [
        "${toString port}:80"
      ];
      # Run as same user as OpenClaw (1000) to ensure read/write access
      user = "1000:1000";

      # Use a custom entrypoint to set the password before starting the server.
      # This avoids database locking issues that occur with postStart scripts.
      entrypoint = "/bin/sh";
      cmd = [
        "-c"
        ''
          # Update admin password from secret
          if [ -f /run/secrets/admin_password ]; then
             # Try updating existing user, fallback to creating new admin
             filebrowser users update admin --password "$(cat /run/secrets/admin_password)" || \
             filebrowser users add admin --password "$(cat /run/secrets/admin_password)" --perm.admin
          fi

          # Start the server
          exec filebrowser
        ''
      ];
      autoStart = true;
    };
  };

  # ===================
  # Pre-start setup
  # ===================
  systemd.services.docker-filebrowser.preStart = ''
    mkdir -p ${dataDir}/config

    # Ensure data directory permissions
    chown -R 1000:1000 ${dataDir}
    chmod -R 700 ${dataDir}

    # Copy the SOPS secret to a location accessible by the container user (1000)
    # The original secret file is usually 0400 root:root, which user 1000 cannot read.
    install -m 0400 -o 1000 -g 1000 ${config.sops.secrets.filebrowser_password.path} ${dataDir}/admin_password
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
