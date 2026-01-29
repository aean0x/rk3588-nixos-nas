# Kernel configuration for ROCK5 ITX (mainline, EDK2 UEFI)
{
  lib,
  pkgs,
  settings,
  ...
}:

let
  kernelPkgs = pkgs.${settings.kernelPackage};
in
{
  boot.kernelPackages = kernelPkgs;

  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
  hardware.enableRedistributableFirmware = true;
  networking.useDHCP = lib.mkDefault true;

  hardware.deviceTree = {
    enable = true;
    name = "rockchip/rk3588-rock-5-itx.dtb";
    filter = "*-rock-5-itx*.dtb";
  };

  # Copy DTB to EFI partition for EDK2 override (adjust path if using different loader)
  boot.loader.systemd-boot.extraFiles."dtb/rockchip/rk3588-rock-5-itx.dtb" =
    "${kernelPkgs.kernel}/dtbs/rockchip/rk3588-rock-5-itx.dtb";

  boot = {
    kernelParams = [
      "rootwait"
      "earlycon"
      "consoleblank=0"
      "console=tty1" # primary framebuffer console
      "console=ttyS2,115200n8" # most common RK3588 debug UART; change baud if needed
      # "dtb=/rockchip/rk3588-rock-5-itx.dtb"  # uncomment only if EDK2 not passing DTB

      # Optional debug / splash
      # "splash"
      # "plymouth.ignore-serial-consoles"
      # "ignore_loglevel"
    ];

    initrd.availableKernelModules = [
      "nvme" # NVMe
      "mmc_block" # SD / eMMC
      "hid" # USB keyboards during initrd
      "dm_mod" # LVM / LUKS
      "dm_crypt" # LUKS
      "input_leds"
      # Add rockchip_* display / DRM modules if early KMS desired (usually auto-loaded later)
    ];
  };
}
