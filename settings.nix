# System settings - edit for your fork
# Secrets (passwords, WiFi PSK, API keys) go in secrets/secrets.yaml
{
  # System identification
  hostName = "rocknas";
  description = "ROCK5 ITX NAS Server";
  timeZone = "Europe/Berlin";

  # Admin user
  adminUser = "user";
  setupPassword = "nixos"; # Temp password for ISO SSH access

  # SSH configuration
  allowPasswordAuth = false;

  # SSH public keys for authentication (one per line)
  # Get your key with: cat ~/.ssh/id_ed25519.pub
  sshPubKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICB8EtGX5PD1QPF/jrdd5G+fQy4tV2L3fhCY1dhZc4ep aean@nix-pc"
    # "ssh-ed25519 AAAA... user@laptop"
  ];

  # Public domain (subdomains like ha.aean.io are created per-service)
  domain = "aean.io";

  # Repository (format: "owner/repo")
  repoUrl = "aean0x/rock-5-nas";

  # Network configuration (static IP)
  network = {
    interface = "enP4p65s0"; # Rock 5 ITX primary ethernet
    address = "192.168.1.200";
    prefixLength = 24;
    gateway = "192.168.1.1";
    dnsPrimary = "1.1.1.1";
    dnsSecondary = "8.8.8.8";
  };

  # Optional WiFi (client mode — mutually exclusive with router mode)
  enableWifi = false;
  wifiSsid = "SKYNET";

  # Router mode — configure in services/router.nix
  enableRouter = false;

  # Thread radio (uncomment and set if you have a Thread USB adapter)
  threadRadioPath = "/dev/serial/by-id/usb-Nabu_Casa_ZBT-2_DCB4D910EF08-if00";
  baudRate = 460800;

  # Build systems
  hostSystem = "x86_64-linux"; # System building the ISO
  targetSystem = "aarch64-linux";
  stateVersion = "25.11";

  # Kernel version (e.g., linuxPackages_6_18, linuxPackages_latest)
  kernelPackage = "linuxPackages_7_1";

  # Hermes Robinhood Crypto MCP secrets (read-only data server).
  # After adding robinhood_crypto_api_key + robinhood_crypto_private_key to
  # secrets.yaml (see secrets.yaml.example + hosts/system/hermes/BOOTSTRAP.md),
  # set true so sops materializes /run/hermes-robinhood.env. MCP itself is
  # always declared; without secrets it only exposes get_setup_status.
  enableRobinhoodCryptoSecrets = false;
}
