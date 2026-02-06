# System settings - edit for your fork
# SOPS secrets config is in secrets/sops.nix
let
  repoUrl = "aean0x/rock-5-nas"; # Format: "owner/repo"
  parts = builtins.split "/" repoUrl;
in
{
  # System identification
  hostName = "rock-5-nas";
  description = "ROCK5 ITX NAS Server";

  # Admin user
  adminUser = "user";
  setupPassword = "nixos"; # Temp password for ISO SSH access

  # SSH public keys for authentication (one per line)
  # Get your key with: cat ~/.ssh/id_ed25519.pub
  sshPubKeys = [
    "ssh-ed25519 AAAA... user@workstation"
    # "ssh-ed25519 AAAA... user@laptop"
  ];

  # Repository coordinates (parsed from repoUrl)
  inherit repoUrl;
  repoOwner = builtins.elemAt parts 0;
  repoName = builtins.elemAt parts 2;

  # Build systems
  hostSystem = "x86_64-linux"; # System building the ISO
  targetSystem = "aarch64-linux";
  stateVersion = "25.11";

  # Kernel version (e.g., linuxPackages_6_18, linuxPackages_latest)
  kernelPackage = "linuxPackages_6_18";
}
