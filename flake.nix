{
  description = "NixOS configuration for ROCK 5 ITX";

  # Garnix hosted cache shut down 2026-07-15 — do not re-add cache.garnix.io.
  # Default cache.nixos.org is enough; optional private caches via Cachix/Attic.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    # gbrain 0.60 refuses Bun < 1.4. The locked nixpkgs bun is 1.3.13.
    nixpkgs-bun.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Hermes Agent (NousResearch). Pin a release tag, never main: upstream
    # main carries version = "0.0.0" (the real version is set at release), so
    # a main-tracking build reports 0.0.0 and every plugin behind a
    # `requires_hermes` floor silently drops out of the tool surface. Main
    # also moves the sealed venv's dependency set under us. Bump the tag
    # deliberately.
    hermes-agent.url = "github:NousResearch/hermes-agent/v2026.9.24";
    hermes-webui.url = "github:nesquena/hermes-webui";
    # Media stack: Sonarr/Radarr (+ optional others) with declarative settings-sync
    nixarr.url = "github:nix-media-server/nixarr";
    hermes-pnp = {
      url = "github:aean0x/hermes-pnp";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.hermes-agent.follows = "hermes-agent";
      inputs.hermes-webui.follows = "hermes-webui";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-stable,
    nixpkgs-bun,
    sops-nix,
    nixarr,
    ...
  } @ inputs: let
    settings = import ./settings.nix;
    system = settings.targetSystem;
    # Workstation vs on-device. Used so the live system can stay qemu-native
    # aarch64 for userspace while the kernel still comes from pkgsCross.
    evalHost = builtins.currentSystem or settings.hostSystem;

    overlays = [
      (final: prev: {
        stable = import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
        };
        # Upstream bun cannot exec here (NixOS stub-ld). Take Bun 1.4 from
        # nixpkgs-bun so the hermes toolbox, which is ahead of ~/.bun/bin
        # on PATH, can start gbrain.
        bun = (import nixpkgs-bun {
          system = prev.stdenv.hostPlatform.system;
          config.allowUnfree = true;
        }).bun;
        # ncdu 2.x is Zig. zig 0.16 translate-c emits x86_64 objects and
        # links them as aarch64 ("incompatible with elf64-littleaarch64").
        # 1.x is C and cross-compiles.
        ncdu = prev.ncdu_1;
      })
    ];

    # Shared modules for installer images (ISO + netboot)
    installerModules = [
      ./hardware-configuration.nix
      ./hosts/iso/default.nix
      {
        nixpkgs.crossSystem.system = settings.targetSystem;
        nixpkgs.localSystem.system = settings.hostSystem;
      }
    ];
  in {
    nixosConfigurations.${settings.hostName} = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit inputs settings evalHost;};
      modules = [
        {
          nixpkgs.overlays = overlays;
          # Userspace is native aarch64 (qemu-user/binfmt on the workstation).
          # PR #86 set crossSystem here and broke gh/haskell/dotnet/zig/bun.
          # Kernel is still CROSS_COMPILE via pkgsCross in hardware-configuration.nix.
        }
        sops-nix.nixosModules.sops
        nixarr.nixosModules.default
        ./hardware-configuration.nix
        ./hosts/system/default.nix
        ./secrets/sops.nix
        ./scripts/scripts.nix
      ];
    };

    nixosConfigurations."${settings.hostName}-ISO" = nixpkgs.lib.nixosSystem {
      system = settings.targetSystem;
      specialArgs = {inherit inputs settings evalHost;};
      modules =
        [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          (
            {config, ...}: {
              isoImage = {
                volumeID = builtins.substring 0 32 "${settings.hostName}_${config.system.nixos.label}";
                makeEfiBootable = true;
                makeBiosBootable = false;
              };
            }
          )
        ]
        ++ installerModules;
    };

    nixosConfigurations."${settings.hostName}-netboot" = nixpkgs.lib.nixosSystem {
      system = settings.targetSystem;
      specialArgs = {inherit inputs settings evalHost;};
      modules =
        [
          "${nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
        ]
        ++ installerModules;
    };

    packages.${settings.hostSystem} = {
      iso = self.nixosConfigurations."${settings.hostName}-ISO".config.system.build.isoImage;
      netboot = let
        cfg = self.nixosConfigurations."${settings.hostName}-netboot".config.system.build;
        ipxeArm64 = nixpkgs.legacyPackages.${settings.hostSystem}.pkgsCross.aarch64-multiplatform.ipxe;
      in
        nixpkgs.legacyPackages.${settings.hostSystem}.runCommand "netboot-${settings.hostName}" {} ''
          mkdir -p $out
          ln -s ${cfg.kernel}/Image $out/Image
          ln -s ${cfg.netbootRamdisk}/initrd $out/initrd
          cp ${cfg.netbootIpxeScript}/netboot.ipxe $out/netboot.ipxe
          cp ${ipxeArm64}/snp.efi $out/snp.efi
        '';
    };
  };
}
