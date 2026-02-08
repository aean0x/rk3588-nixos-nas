# OneDrive sync for OpenClaw workspace (rclone copy, no deletions)
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
      User = "openclaw";
      Group = "openclaw";
      Environment = [
        "HOME=/var/lib/openclaw"
      ];
      ExecStart = [
        "${pkgs.bash}/bin/bash"
        "-lc"
        ''
          set -euo pipefail
          mkdir -p "${workspaceRoot}/Shared" "${workspaceRoot}/Documents"
          ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "onedrive:Shared" "${workspaceRoot}/Shared"
          ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "${workspaceRoot}/Shared" "onedrive:Shared"
          ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "onedrive:Documents" "${workspaceRoot}/Documents"
          ${pkgs.rclone}/bin/rclone copy --update --config "${onedriveConfig}" "${workspaceRoot}/Documents" "onedrive:Documents"
        ''
      ];
    };
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
