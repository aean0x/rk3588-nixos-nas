{
  description = "NixOS configuration for ROCK 5 ITX";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixarr = {
      url = "github:rasmus-kirk/nixarr";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      sops-nix,
      nixarr,
      ...
    }@inputs:
    let
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
    in
    {
      nixosConfigurations.${settings.hostName} = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs settings; };
        modules = [
          { nixpkgs.overlays = overlays; }
          sops-nix.nixosModules.sops
          ./hardware-configuration.nix
          ./hosts/system/default.nix
          ./secrets/sops.nix
          ./scripts/scripts.nix
          nixarr.nixosModules.default
        ];
      };

      nixosConfigurations."${settings.hostName}-ISO" = nixpkgs.lib.nixosSystem {
        system = settings.targetSystem;
        specialArgs = { inherit inputs settings; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          (
            { config, ... }:
            {
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
        specialArgs = { inherit inputs settings; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
        ]
        ++ installerModules;
      };

      packages.${settings.hostSystem} = {
        iso = self.nixosConfigurations."${settings.hostName}-ISO".config.system.build.isoImage;
        netboot =
          let
            cfg = self.nixosConfigurations."${settings.hostName}-netboot".config.system.build;
            ipxeArm64 = nixpkgs.legacyPackages.${settings.hostSystem}.pkgsCross.aarch64-multiplatform.ipxe;
          in
          nixpkgs.legacyPackages.${settings.hostSystem}.runCommand "netboot-${settings.hostName}" { } ''
            mkdir -p $out
            ln -s ${cfg.kernel}/Image $out/Image
            ln -s ${cfg.netbootRamdisk}/initrd $out/initrd
            cp ${cfg.netbootIpxeScript}/netboot.ipxe $out/netboot.ipxe
            cp ${ipxeArm64}/snp.efi $out/snp.efi
          '';
      };
    };
}
