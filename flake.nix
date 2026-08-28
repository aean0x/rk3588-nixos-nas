{
  description = "NixOS configuration for ROCK 5 ITX";

  # Garnix hosted cache shut down 2026-07-15 — do not re-add cache.garnix.io.
  # Default cache.nixos.org is enough; optional private caches via Cachix/Attic.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Hermes Agent (NousResearch). Was temporarily pinned to v0.19.1 for a
    # hermes-web/tui package-lock ENOTCACHED issue; unpinned after v0.20.0.
    hermes-agent.url = "github:NousResearch/hermes-agent";
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
    sops-nix,
    nixarr,
    ...
  } @ inputs: let
    settings = import ./settings.nix;
    system = settings.targetSystem;

    overlays = [
      (final: prev: {
        stable = import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
        };
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
      specialArgs = {inherit inputs settings;};
      modules = [
        {
          nixpkgs.overlays = overlays;
          # Same as installerModules: build on the workstation, target the
          # board. Without localSystem the kernel is an aarch64 drv and
          # remote-switch qemu-user-emulates gcc (day-scale for 7.1).
          nixpkgs.crossSystem.system = settings.targetSystem;
          nixpkgs.localSystem.system = settings.hostSystem;
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
      specialArgs = {inherit inputs settings;};
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
      specialArgs = {inherit inputs settings;};
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
