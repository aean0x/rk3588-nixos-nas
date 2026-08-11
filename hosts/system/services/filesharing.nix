# LAN file share — NFS + SMB guest, entire data drive at /media.
#
#   smb://rocknas.local/Media   (guest, no password)
#   mount -t nfs rocknas.local:/media …
#
# Drop TorBox / yt-dlp / anything here: Videos/, Files/, …
# Custom NFS lockd/mountd/statd ports keep the firewall explicit.
{
  lib,
  pkgs,
  settings,
  ...
}:
let
  lan = "192.168.1.0/24";
  # Data pool root (Videos, Files, …).
  shareRoot = "/media";
  # Align with nixarr media group (util-nixarr.globals.gids.media = 169).
  mediaGid = 169;
in
{
  # Guest writes land as nobody:media (gid fixed so /etc/exports is never empty).
  # mkDefault so nixarr's fixed media gid wins if both set.
  users.groups.media.gid = lib.mkDefault mediaGid;
  users.users.nobody.extraGroups = [ "media" ];

  systemd.tmpfiles.rules = [
    "d ${shareRoot} 2775 nobody media - -"
    "d ${shareRoot}/Videos 2775 nobody media - -"
    "d ${shareRoot}/Videos/Movies 2775 nobody media - -"
    "d ${shareRoot}/Videos/Shows 2775 nobody media - -"
    "d ${shareRoot}/Videos/Music Videos 2775 nobody media - -"
    "d ${shareRoot}/Files 2775 nobody media - -"
    "d ${shareRoot}/Files/Share 2775 nobody media - -"
  ];

  # Normalize ownership/modes on the whole pool (hourly + on change).
  systemd.services.files-media-sanitize = {
    description = "Normalize permissions on /media share root";
    unitConfig.ConditionPathIsDirectory = shareRoot;
    serviceConfig = {
      Type = "oneshot";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    path = [
      pkgs.findutils
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail
      # Pool root + common trees: guest-writable, group media.
      chown nobody:media ${shareRoot} || true
      chmod 2775 ${shareRoot} || true
      for d in Videos Files; do
        if [ -d ${shareRoot}/$d ]; then
          chown -R nobody:media ${shareRoot}/$d || true
          find ${shareRoot}/$d -type d -exec chmod 2775 {} +
          find ${shareRoot}/$d -type f -exec chmod 0664 {} +
        fi
      done
    '';
  };

  systemd.paths.files-media-sanitize = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = shareRoot;
      TriggerLimitBurst = 3;
      TriggerLimitIntervalSec = "60s";
    };
  };

  systemd.timers.files-media-sanitize = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };

  # One-shot boot fix for existing trees (Sara/user leftovers, Videos modes).
  systemd.services.files-media-sanitize-boot = {
    description = "Boot-time /media permission fixup";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathIsDirectory = shareRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.findutils
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail
      chown nobody:media ${shareRoot} || true
      chmod 2775 ${shareRoot} || true
      for d in Videos Files; do
        if [ -d ${shareRoot}/$d ]; then
          chown -R nobody:media ${shareRoot}/$d || true
          find ${shareRoot}/$d -type d -exec chmod 2775 {} +
          find ${shareRoot}/$d -type f -exec chmod 0664 {} +
        fi
      done
    '';
  };

  services.nfs.server = {
    enable = true;
    lockdPort = 4001;
    mountdPort = 4002;
    statdPort = 4000;
    exports = ''
      ${shareRoot} ${lan}(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=${toString mediaGid},insecure)
    '';
  };

  networking.firewall.allowedTCPPorts = [
    111
    2049
    4000
    4001
    4002
  ];
  networking.firewall.allowedUDPPorts = [
    111
    2049
    4000
    4001
    4002
  ];

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
        "server max protocol" = "SMB3";
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:metadata" = "stream";
        "fruit:model" = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";
        logging = "systemd";
        "log level" = "1";
      };

      # Whole data drive — Videos/, Files/, …
      Media = {
        path = shareRoot;
        comment = "Entire /media pool (guest, no password)";
        browseable = "yes";
        writable = "yes";
        "guest ok" = "yes";
        "guest only" = "yes";
        "force user" = "nobody";
        "force group" = "media";
        "create mask" = "0664";
        "directory mask" = "2775";
        "force create mode" = "0664";
        "force directory mode" = "2775";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

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
