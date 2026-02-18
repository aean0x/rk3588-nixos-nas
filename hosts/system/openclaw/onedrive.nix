# OneDrive sync for OpenClaw workspace (rclone copy, no deletions)
# Runs as UID 1000 to match Docker container user in openclaw-docker.nix
{ config, pkgs, ... }:
let
  workspaceRoot = "/var/lib/openclaw/workspace";
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
        "HOME=/var/lib/openclaw"
      ];
    };

    script = ''
      set -euo pipefail

      RCLONE_CONF="/tmp/onedrive-rclone.conf"
      cp "${onedriveConfig}" "$RCLONE_CONF"
      chmod 600 "$RCLONE_CONF"
      trap 'rm -f "$RCLONE_CONF"' EXIT

      mkdir -p "${workspaceRoot}/onedrive/Shared" "${workspaceRoot}/onedrive/Documents"
      RCLONE="${pkgs.rclone}/bin/rclone copy --update --config $RCLONE_CONF"
      $RCLONE "onedrive:Shared" "${workspaceRoot}/onedrive/Shared"
      $RCLONE "${workspaceRoot}/onedrive/Shared" "onedrive:Shared"
      $RCLONE "onedrive:Documents" "${workspaceRoot}/onedrive/Documents"
      $RCLONE "${workspaceRoot}/onedrive/Documents" "onedrive:Documents"
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
