# Printing support for USB/network printers.
# For the Epson (connected via USB), this pulls in CUPS + epson-escpr driver.
# After deploy, the printer should appear in `lpinfo -v` as usb://...
# Configure with: lpadmin -p myprinter -E -v usb://... -m epson-escpr:...
# Or point a browser at http://rocknas.local:631 (or 192.168.2.1:631)
# User "user" gets lp group for direct printing.
{ config, pkgs, settings, lib, ... }:

{
  services.printing = {
    enable = true;
    drivers = with pkgs; [
      epson-escpr # ESC/P-R driver for most Epson inkjets (ET/WF etc.)
      # Add more if needed: gutenprint, hplip, etc.
    ];
    # Optional: allow network browsing/sharing of the printer
    browsing = true;
    defaultShared = true;
  };

  # Scanning support (if your Epson is an all-in-one)
  hardware.sane.enable = true;
  # services.saned.enable = true; # if you want to scan over network from other machines

  # Give the admin user permission to print/scan without sudo
  users.users.${settings.adminUser}.extraGroups = [ "lp" "scanner" ];

  # If the printer needs specific udev rules (rare for Epson with the driver)
  # services.udev.packages = [ pkgs.epson-escpr ];
}
