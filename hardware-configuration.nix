# Kernel configuration for ROCK5 ITX (mainline, EDK2 UEFI)
{
  lib,
  pkgs,
  settings,
  inputs,
  evalHost ? settings.targetSystem,
  ...
}:

let
  # Live system userspace is qemu-native aarch64 (no nixpkgs.crossSystem).
  # Kernel stays real CROSS_COMPILE so gcc is not qemu-user (19h last time).
  # ISO/netboot already set crossSystem — pkgs is already crossing there.
  # On-device switch: evalHost is aarch64, use pkgs as-is.
  alreadyCross = pkgs.stdenv.buildPlatform.system != pkgs.stdenv.hostPlatform.system;
  kernelBasePkgs =
    if alreadyCross || evalHost == settings.targetSystem then
      pkgs
    else
      inputs.nixpkgs.legacyPackages.${evalHost}.pkgsCross.aarch64-multiplatform;

  # Kernel is one nix job. deploy --cores 12 would leave half the
  # workstation idle on a 7.x rebuild. Use every thread; NixOS's
  # kernel.override (patches) is wrapped so this survives.
  addCores = drv:
    drv.overrideAttrs (old: {
      preBuild = (old.preBuild or "") + ''
        export NIX_BUILD_CORES=$(nproc)
      '';
    });
  kernelPkgs = kernelBasePkgs.${settings.kernelPackage}.extend (
    _self: super: {
      kernel =
        (addCores super.kernel)
        // {
          override = args: addCores (super.kernel.override args);
        };
    }
  );
in
{
  boot.kernelPackages = kernelPkgs;

  # ath12k (WCN7850) 5GHz AP: self-managed regdom requires these to accept user hints
  boot.kernelPatches = [
    {
      name = "ath12k-5ghz-ap";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        CFG80211_CERTIFICATION_ONUS = yes;
        ATH_REG_DYNAMIC_USER_REG_HINTS = yes;
      };
    }
  ];

  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom="US"
  '';

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
