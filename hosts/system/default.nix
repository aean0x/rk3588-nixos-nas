# Main system configuration for ROCK5 ITX
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:

{
  imports = [
    ./packages.nix
    ./partitions.nix
    ./services.nix
    ./containers.nix
    ./tasks.nix
  ];

  # ===================
  # Networking
  # ===================
  networking = {
    hostName = settings.hostName;
    useDHCP = false;
    enableIPv6 = true;
    interfaces.${settings.network.interface} = lib.mkIf (!(settings.enableRouter or false)) {
      ipv4.addresses = [
        {
          address = settings.network.address;
          prefixLength = settings.network.prefixLength;
        }
      ];
    };

    defaultGateway = lib.mkIf (!(settings.enableRouter or false)) settings.network.gateway;
    # Prefer local AdGuard (see settings.network.hostNameservers). Upstream
    # public DNS lives only on AdGuard — host bypass caused uncached EAI_AGAIN
    # storms under concurrent hermes cron (2026-08-06).
    nameservers = settings.network.hostNameservers or [
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
    # In router mode only advertise on the LAN bridge — the WAN interface
    # gets a CGNAT address that LAN clients can't reach.
    allowInterfaces = lib.mkIf (settings.enableRouter or false) [ "br0" ];
  };

  # avahi-daemon leaves a stale PID file when killed mid-flight during
  # NixOS generation switches, causing the next start to fail with EXCEPTION.
  systemd.services.avahi-daemon.serviceConfig.ExecStartPre =
    "+${pkgs.coreutils}/bin/rm -f /run/avahi-daemon/pid";

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
    # Official Hydra cache only. Garnix (cache.garnix.io) shut down 2026-07-15.
    substituters = [ "https://cache.nixos.org/" ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  # ===================
  # System
  # ===================
  time.timeZone = settings.timeZone;
  system.stateVersion = settings.stateVersion;

  # Site git author (settings.nix). hermes-pnp adds credential.helper.
  # ISO sets programs.git.enable = false.
  programs.git = settings.programs.git or { };
}
