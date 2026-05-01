# AdGuard Home DNS (native NixOS, fully declarative)
{
  settings,
  ...
}:
let
  port = 3000;
  lanIP = if (settings.enableRouter or false) then "192.168.2.1" else settings.network.address;
in
{
  services.caddy.proxyServices = {
    "adguard.${settings.domain}" = port;
  };

  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    settings = {
      schema_version = 32;

      http.address = "0.0.0.0:${toString port}";

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

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        rewrites_enabled = true;
        safebrowsing_enabled = true;
        parental_enabled = false;
        blocking_mode = "default";

        safe_search = {
          enabled = false;
          bing = true;
          duckduckgo = true;
          google = true;
          youtube = true;
          yandex = true;
        };

        rewrites = [
          {
            domain = settings.domain;
            answer = lanIP;
            enabled = true;
          }
          {
            domain = "*.${settings.domain}";
            answer = lanIP;
            enabled = true;
          }
        ];
      };

      # prettier-ignore
      filters = [
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
          name = "AdGuard DNS filter";
          id = 1;
        }
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
          name = "AdAway Default Blocklist";
          id = 2;
        }
        {
          enabled = true;
          url = "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-agh-online.txt";
          name = "Malware URL Blocklist";
          id = 3;
        }
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_44.txt";
          name = "Phishing URL Blocklist";
          id = 4;
        }
      ];
    };
  };

  # systemd-resolved conflicts with port 53
  services.resolved.enable = false;

  networking.firewall = {
    allowedTCPPorts = [
      53
      port
    ];
    allowedUDPPorts = [ 53 ];
  };
}
