# OneDrive sync for Hermes workspace (rclone copy, non-destructive)
# Runs as the hermes user so files are owned correctly for the agent.
{
  config,
  pkgs,
  ...
}:
let
  onedriveConfig = config.sops.secrets.onedrive_rclone_config.path;
  stateDir = config.services.hermes-agent.stateDir;
  workspace = "${stateDir}/workspace";
in
{
  environment.systemPackages = [ pkgs.rclone ];

  systemd.tmpfiles.rules = [
    "d ${workspace}/onedrive 2770 hermes hermes - -"
  ];

  systemd.services.onedrive-sync = {
    description = "Sync OneDrive folders into Hermes workspace (non-destructive)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      Environment = [ "HOME=${stateDir}" ];
      # Secret is 0400 root:root under /run/secrets; hermes cannot stat it.
      LoadCredential = "rclone.conf:${onedriveConfig}";
      RuntimeDirectory = "onedrive-sync";
      RuntimeDirectoryMode = "0700";
    };

    script = ''
      set -euo pipefail

      RCLONE_CONF="$RUNTIME_DIRECTORY/rclone.conf"
      cp "$CREDENTIALS_DIRECTORY/rclone.conf" "$RCLONE_CONF"
      chmod 600 "$RCLONE_CONF"
      mkdir -p "${workspace}/onedrive/Shared" "${workspace}/onedrive/Documents"
      RCLONE="${pkgs.rclone}/bin/rclone copy --update --config $RCLONE_CONF"
      $RCLONE "onedrive:Shared" "${workspace}/onedrive/Shared"
      $RCLONE "${workspace}/onedrive/Shared" "onedrive:Shared"
      $RCLONE "onedrive:Documents" "${workspace}/onedrive/Documents"
      $RCLONE "${workspace}/onedrive/Documents" "onedrive:Documents"
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
