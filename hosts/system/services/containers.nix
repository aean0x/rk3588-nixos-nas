# Docker/Podman engine, ZFS storage, auto-pull/restart timers
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  containerNames = builtins.attrNames config.virtualisation.oci-containers.containers;
in
{
  # ===================
  # Docker Engine
  # ===================
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    autoPrune.enable = true;
  };

  # ===================
  # Podman (daemonless, for ZFS-backed containers)
  # ===================
  virtualisation.podman = {
    enable = true;
    dockerCompat = false; # Keep false when real Docker daemon is enabled
    defaultNetwork.settings.dns_enabled = true;
    autoPrune.enable = true;
  };

  virtualisation.containers.storage.settings = {
    storage = {
      driver = "zfs";
      graphroot = "/var/lib/containers/storage";
    };
  };

  virtualisation.oci-containers.backend = "docker";

  # ===================
  # Auto-pull container images (weekly)
  # ===================
  systemd.timers.pull-containers = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 02:00:00";
      Persistent = true;
    };
  };

  systemd.services.pull-containers = {
    script = builtins.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: container: "${config.virtualisation.docker.package}/bin/docker pull ${container.image}"
      ) config.virtualisation.oci-containers.containers
    );
    serviceConfig.Type = "oneshot";
  };

  # ===================
  # Periodic restart timer (weekly)
  # ===================
  systemd.timers.restart-services = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 03:30:00";
      Persistent = true;
    };
  };

  systemd.services.restart-services = {
    script = ''
      ${config.virtualisation.docker.package}/bin/docker restart \
        ${builtins.concatStringsSep " " containerNames} || true
    '';
    serviceConfig.Type = "oneshot";
  };

  # ===================
  # Packages & user groups
  # ===================
  environment.systemPackages = with pkgs; [
    docker-compose
    podman-compose
    dive
  ];

  users.users.${settings.adminUser}.extraGroups = [
    "docker"
    "podman"
  ];
}
