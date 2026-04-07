# Samba file shares
# /media — wide-open read-write for LAN (no auth)
# /var/lib/openclaw — read-only for LAN
# Tailscale clients reach these via advertised LAN route (192.168.1.0/24)
{
  settings,
  ...
}:
{
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "server string" = settings.hostName;
        "map to guest" = "Bad User";
        "guest account" = "nobody";
        security = "user";
        "server min protocol" = "SMB2";
        logging = "systemd";
        "log level" = "1";
      };
      Media = {
        path = "/media";
        browseable = "yes";
        writable = "yes";
        "guest ok" = "yes";
        "force user" = "nobody";
        "force group" = "nogroup";
        "create mask" = "0666";
        "directory mask" = "0777";
      };

    };
  };

  # Ensure /media is writable by nobody (sticky bit prevents cross-user delete)
  systemd.tmpfiles.rules = [
    "d /media 1777 nobody nogroup - -"
  ];

  # wsdd — Windows/Linux network discovery for Samba
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  # Avahi SMB advertisement — shows shares in Nemo/Nautilus "Network" tab
  services.avahi.extraServiceFiles.smb = ''
    <?xml version="1.0" standalone='no'?>
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h</name>
      <service>
        <type>_smb._tcp</type>
        <port>445</port>
      </service>
    </service-group>
  '';
}
