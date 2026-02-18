# Docker engine, storage config, unified container refresh
# Container modules live in ./containers/
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  containerNames = builtins.attrNames config.virtualisation.oci-containers.containers;
  containerImages = lib.mapAttrsToList (_: c: c.image) config.virtualisation.oci-containers.containers;
  uniqueImages = lib.unique containerImages;
in
{
  imports = [
    ./containers/home-assistant.nix
    ./containers/filebrowser.nix
    ./openclaw
  ];

  # ===================
  # Docker Engine
  # ===================
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--filter=until=168h" ];
    };
  };

  virtualisation.oci-containers.backend = "docker";

  # ===================
  # Unified container refresh (pull images + restart services)
  # ===================
  systemd.services.refresh-containers = {
    description = "Pull latest container images and restart services";
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      echo "Pulling container images..."
      ${lib.concatMapStringsSep "\n" (img: ''
        echo "  ${img}"
        ${config.virtualisation.docker.package}/bin/docker pull ${img} || true
      '') uniqueImages}

      echo "Restarting containers..."
      ${config.virtualisation.docker.package}/bin/docker restart ${lib.concatStringsSep " " containerNames} || true

      echo "Container refresh complete."
    '';
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
  };

  systemd.timers.refresh-containers = {
    description = "Weekly container image refresh";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 02:00:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # ===================
  # Packages & user groups
  # ===================
  environment.systemPackages = with pkgs; [
    docker-compose
    dive
  ];

  users.users.${settings.adminUser}.extraGroups = [ "docker" ];
}
