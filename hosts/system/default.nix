# Main system configuration for ROCK5 ITX
{
  config,
  lib,
  settings,
  ...
}:

{
  imports = [
    ./packages.nix
    ./partitions.nix
    ./services.nix
  ];

  # ===================
  # Networking
  # ===================
  networking = {
    hostName = settings.hostName;
    useDHCP = false; # Using static IP below
    enableIPv6 = true;
    hostId = "8425e349"; # Required for ZFS

    interfaces.${settings.network.interface} = {
      ipv4.addresses = [
        {
          address = settings.network.address;
          prefixLength = settings.network.prefixLength;
        }
      ];
    };

    defaultGateway = settings.network.gateway;
    nameservers = [
      settings.network.dnsPrimary
      settings.network.dnsSecondary
    ];

    wireless = lib.mkIf (settings.enableWifi or false) {
      enable = true;
      secretsFile = config.sops.templates.wifiEnv.path;
      networks."${settings.wifiSsid}".psk = "@WIFI_PSK@";
    };
  };

  # ===================
  # SSH & Discovery
  # ===================
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = settings.allowPasswordAuth;
    settings.PermitRootLogin = "no";
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish.enable = true;
    publish.addresses = true;
  };

  # Enable Bluetooth (required for Matter commissioning)
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # ===================
  # Boot configuration (Rock5 ITX specific)
  # ===================
  boot.loader = {
    systemd-boot = {
      enable = true;
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

  # Prevent "Too many open files" errors with inotify-based file watchers
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 512;
  };

  # ===================
  # User
  # ===================
  users.groups.media = { };

  users.users.${settings.adminUser} = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.user_hashedPassword.path;
    description = settings.description;
    extraGroups = [
      "wheel"
      "video"
      "media"
    ];
    openssh.authorizedKeys.keys = settings.sshPubKeys;
  };

  security.sudo.wheelNeedsPassword = false;

  # ===================
  # Logging & Misc
  # ===================
  services.journald.extraConfig = "SystemMaxUse=1000M";

  nix.settings = {
    trusted-users = [ "@wheel" ];
    substituters = [
      "https://cache.nixos.org/"
      "https://cache.garnix.io"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    ];
  };

  # ===================
  # System
  # ===================
  time.timeZone = settings.timeZone;
  system.stateVersion = settings.stateVersion;
}
