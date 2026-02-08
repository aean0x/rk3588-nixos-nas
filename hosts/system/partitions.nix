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

  # ZFS pool mount
  # First boot: create pool, then rebuild:
  #   sudo zpool create -o ashift=12 -O compression=lz4 -O atime=off -O mountpoint=/media media mirror /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2>
  fileSystems."/media" = {
    device = "media";
    fsType = "zfs";
    options = [
      "nofail"
    ];
  };

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
