# System tasks and cron jobs
{ settings, ... }:

let
  flakeRef = "github:${settings.repoUrl}#${settings.hostName}";
in
{
  # Automatic system upgrades
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    flake = flakeRef;
    dates = "Sun *-*-* 03:00:00";
    randomizedDelaySec = "30min";
  };

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
