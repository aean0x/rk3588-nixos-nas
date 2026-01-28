# Remote desktop configuration (XFCE + xrdp)
{ settings, ... }:

{
  services.xserver = {
    enable = true;
    desktopManager = {
      xfce.enable = true;
      xterm.enable = false;
    };
    displayManager.lightdm.enable = true;
  };

  # Session and auto-login now live under services.displayManager
  services.displayManager = {
    defaultSession = "xfce";
    autoLogin = {
      enable = true;
      user = settings.adminUser;
    };
  };

  services.xrdp = {
    enable = true;
    defaultWindowManager = "xfce4-session";
    openFirewall = true;
  };
}
