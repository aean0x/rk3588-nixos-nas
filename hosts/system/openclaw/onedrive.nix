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
      Group = "1000";
      Environment = [
        "HOME=/var/lib/openclaw"
      ];
    };

    script = ''
      set -euo pipefail
      mkdir -p "${workspaceRoot}/onedrive/Shared" "${workspaceRoot}/onedrive/Documents"
      ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "onedrive:Shared" "${workspaceRoot}/onedrive/Shared"
      ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "${workspaceRoot}/onedrive/Shared" "onedrive:Shared"
      ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "onedrive:Documents" "${workspaceRoot}/onedrive/Documents"
      ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "${workspaceRoot}/onedrive/Documents" "onedrive:Documents"
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
