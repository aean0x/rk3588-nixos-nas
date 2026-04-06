# ./services/cockpit.nix
{ pkgs, settings, ... }:

{
  services.cockpit = {
    enable = true;
    openFirewall = true; # Opens 9090/tcp
    # port = 9090;
  };

  environment.systemPackages = with pkgs; [
    cockpit-podman # Podman containers tab (start/stop/logs/inspect)
    cockpit-storaged # General storage (disks, mounts, LUKS, etc.)
    # cockpit-machines              # Optional: VM management
    # cockpit-sensors               # Hardware sensors (optional)
  ];

  # Allow your user to manage containers in Cockpit (Podman)
  users.users.${settings.adminUser}.extraGroups = [ "podman" ];
}
