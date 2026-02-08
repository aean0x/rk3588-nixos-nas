# AdGuard Home DNS (native NixOS)
{
  settings,
  ...
}:
{
  services.adguardhome = {
    enable = true;
    mutableSettings = true; # Allow web UI config changes to persist
    settings = {
      http = {
        address = "0.0.0.0:3000";
      };
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        upstream_dns = [
          settings.network.dnsPrimary
          settings.network.dnsSecondary
        ];
        bootstrap_dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
    };
  };

  # systemd-resolved conflicts with port 53
  services.resolved.enable = false;

  networking.firewall = {
    allowedTCPPorts = [
      53
      3000
    ];
    allowedUDPPorts = [ 53 ];
  };
}
