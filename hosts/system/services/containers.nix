# ./services/containers.nix
{ pkgs, settings, ... }:

{
  virtualisation = {
    # === Docker daemon (rootful by default) ===
    docker = {
      enable = true;
      enableOnBoot = true;
      # rootless.enable = true;          # ← Uncomment for rootless Docker (recommended if possible)
      autoPrune.enable = true; # Optional: periodic cleanup
    };

    # === Podman (daemonless, preferred on NixOS) ===
    podman = {
      enable = true;
      dockerCompat = false; # ← IMPORTANT: Keep false when real Docker daemon is enabled
      defaultNetwork.settings.dns_enabled = true;
      autoPrune.enable = true;
    };
  };

  # Optional but useful
  environment.systemPackages = with pkgs; [
    docker-compose
    podman-compose
    dive # image inspection
  ];

  # Recommended for ZFS users (Podman)
  virtualisation.containers.storage.settings = {
    storage = {
      driver = "zfs";
      graphroot = "/var/lib/containers/storage"; # or point to a ZFS dataset
    };
  };

  # Optional: rootless Podman for your user
  users.users.${settings.adminUser}.extraGroups = [ "podman" ];
}
