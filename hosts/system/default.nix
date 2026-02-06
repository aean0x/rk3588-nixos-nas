# Main system configuration for ROCK5 ITX
{
  config,
  settings,
  ...
}:

{
  imports = [
    # System configuration
    ./packages.nix
    ./partitions.nix
    ./scripts.nix

    # SOPS secrets
    ../../secrets/sops.nix

    # Services
    # ./services/cockpit.nix
    # ./services/caddy.nix
    # ./services/containers.nix
    ./services/remote-desktop.nix
    # ./services/arr-suite.nix
    # ./services/transmission.nix
    ./services/tasks.nix
  ];

  # System configuration
  networking = {
    hostName = settings.hostName;
    networkmanager.enable = true;
    hostId = "8425e349"; # Required for ZFS. Leave it or randomize it- doesn't matter.
  };

  # mDNS for hostname.local resolution
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish.enable = true;
    publish.addresses = true;
  };

  # Enable SSH access
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "no";
  };

  # Boot configuration
  boot.loader = {
    systemd-boot = {
      enable = true;
      # Generate device tree into EFI partition
      extraFiles.${config.hardware.deviceTree.name} =
        "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";
      extraInstallCommands = ''
        mkdir -p /boot/dtb/base
        cp -r ${config.hardware.deviceTree.package}/rockchip/* /boot/dtb/base/
        sync
      '';
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot/efi";
    };
    timeout = 3;
  };

  # User configuration
  users.users.${settings.adminUser} = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.user_hashedPassword.path;
    description = settings.description;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
    ];
    openssh.authorizedKeys.keys = settings.sshPubKeys;
  };

  system.stateVersion = settings.stateVersion;
}
