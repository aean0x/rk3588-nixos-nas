# Storage configuration for ROCK5 ITX
{
  pkgs,
  ...
}:

{
  # Filesystem mounts (labels created by installer)
  fileSystems."/" = {
    device = "/dev/disk/by-label/ROOT";
    fsType = "ext4";
  };

  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-label/EFI";
    fsType = "vfat";
  };

  # ZFS pools auto-populate

  # ZFS configuration
  boot = {
    supportedFilesystems = [ "zfs" ];
    zfs.forceImportRoot = false;
  };

  services.zfs = {
    autoScrub.enable = true;
    autoSnapshot = {
      enable = true;
      frequent = 4;
      hourly = 24;
      daily = 7;
      weekly = 4;
      monthly = 12;
    };
    trim.enable = true;
  };

  environment.systemPackages = with pkgs; [
    zfs
    zfs-prune-snapshots
  ];
}
