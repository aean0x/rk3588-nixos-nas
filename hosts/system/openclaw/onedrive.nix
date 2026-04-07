# OneDrive sync for OpenClaw workspace (rclone copy, no deletions)
# Runs as UID 1000 to match Docker container user in openclaw-docker.nix
{
  config,
  pkgs,
  oc,
  ...
}:
let
  onedriveConfig = config.sops.secrets.onedrive_rclone_config.path;
in
{
  environment.systemPackages = [ pkgs.rclone ];

  systemd.services.onedrive-sync = {
    description = "Sync OneDrive folders into OpenClaw workspace (non-destructive)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "1000";
      Group = "users";
      Environment = [
        "HOME=${oc.configDir}"
      ];
    };

    script = ''
      set -euo pipefail

      RCLONE_CONF="/tmp/onedrive-rclone.conf"
      cp "${onedriveConfig}" "$RCLONE_CONF"
      chmod 600 "$RCLONE_CONF"
      trap 'rm -f "$RCLONE_CONF"' EXIT

      mkdir -p "${oc.hostWorkspace}/docs/Shared" "${oc.hostWorkspace}/docs/Documents"
      RCLONE="${pkgs.rclone}/bin/rclone copy --update --config $RCLONE_CONF"
      $RCLONE "onedrive:Shared" "${oc.hostWorkspace}/docs/Shared"
      $RCLONE "${oc.hostWorkspace}/docs/Shared" "onedrive:Shared"
      $RCLONE "onedrive:Documents" "${oc.hostWorkspace}/docs/Documents"
      $RCLONE "${oc.hostWorkspace}/docs/Documents" "onedrive:Documents"
    '';
  };

  systemd.timers.onedrive-sync = {
    description = "Periodic OneDrive sync into OpenClaw workspace";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "15m";
      RandomizedDelaySec = "2m";
      Unit = "onedrive-sync.service";
    };

  };
}
