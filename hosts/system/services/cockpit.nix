# ./services/cockpit.nix
{ pkgs, settings, ... }:

{
  services.cockpit = {
    enable = true;
    openFirewall = true; # Opens 9090/tcp
    # port = 9090;
  };

  environment.systemPackages = with pkgs; [
    cockpit-podman # Podman containers tab (start/stop/logs/inspect)
    cockpit-zfs # ZFS pool/dataset/snapshot management (45Drives plugin)
    cockpit-storaged # General storage (disks, mounts, LUKS, etc.)
    # cockpit-machines              # Optional: VM management
    # cockpit-sensors               # Hardware sensors (optional)
  ];

  # Optional improvements
  services.zfs.autoScrub.enable = true;
  services.zfs.autoSnapshot.enable = true; # if you use zfs-auto-snapshot

  # Allow your user to manage containers in Cockpit (Podman)
  users.users.${settings.adminUser}.extraGroups = [ "podman" ];
}
