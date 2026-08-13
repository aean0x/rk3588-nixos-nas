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

  # 8 GiB swapfile on the primary SSD (root ext4). NixOS creates/mkswaps it
  # on activation when `size` is set. Avoids OOM kills under Hermes/build spikes.
  # Not on /media (btrfs RAID) — swap wants local, non-compressed block storage.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 8 * 1024; # MiB
    }
  ];

  # Prefer reclaiming page cache a bit sooner than thrashing; still use swap
  # under pressure so OOM is a last resort on 8 GiB RAM boards.
  boot.kernel.sysctl."vm.swappiness" = 30;

  # Btrfs RAID pool mount
  # First boot: create filesystem, then rebuild:
  #   sudo mkfs.btrfs -d raid1 -m raid1 -L media \
  #     /dev/disk/by-id/ata-TOSHIBA_HDWR440UZSVB_52D0A01PF11J \
  #     /dev/disk/by-id/ata-HUH721212ALE601_8DJYESAH
  fileSystems."/media" = {
    device = "/dev/disk/by-label/media";
    fsType = "btrfs";
    options = [
      "nofail"
      "compress=zstd"
      "noatime"
    ];
  };

  # Btrfs maintenance
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/media" ];
  };

  environment.systemPackages = with pkgs; [
    btrfs-progs
    compsize # show actual compression ratios
  ];
}
