# OneDrive sync for Hermes workspace (rclone copy, non-destructive)
# Runs as the hermes user so files are owned correctly for the agent.
{
  config,
  pkgs,
  hermes,
  ...
}:
let
  onedriveConfig = config.sops.secrets.onedrive_rclone_config.path;
in
{
  environment.systemPackages = [ pkgs.rclone ];

  systemd.services.onedrive-sync = {
    description = "Sync OneDrive folders into Hermes workspace (non-destructive)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      Environment = [ "HOME=${hermes.stateDir}" ];
    };

    script = ''
      set -euo pipefail

      RCLONE_CONF="/tmp/onedrive-rclone.conf"
      cp "${onedriveConfig}" "$RCLONE_CONF"
      chmod 600 "$RCLONE_CONF"
      trap 'rm -f "$RCLONE_CONF"' EXIT

      mkdir -p "${hermes.workspace}/onedrive/Shared" "${hermes.workspace}/onedrive/Documents"
      RCLONE="${pkgs.rclone}/bin/rclone copy --update --config $RCLONE_CONF"
      $RCLONE "onedrive:Shared" "${hermes.workspace}/onedrive/Shared"
      $RCLONE "${hermes.workspace}/onedrive/Shared" "onedrive:Shared"
      $RCLONE "onedrive:Documents" "${hermes.workspace}/onedrive/Documents"
      $RCLONE "${hermes.workspace}/onedrive/Documents" "onedrive:Documents"
    '';
  };

  systemd.timers.onedrive-sync = {
    description = "Periodic OneDrive sync into Hermes workspace";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "15m";
      RandomizedDelaySec = "2m";
      Unit = "onedrive-sync.service";
    };
  };
}
