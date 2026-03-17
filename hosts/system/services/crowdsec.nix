# CrowdSec IDS/IPS with nftables firewall bouncer
# Engine analyzes journald logs (SSH + Caddy), firewall bouncer enforces bans.
# LAPI runs locally on 127.0.0.1:8080. Hub auto-updates daily.
#
# First deploy: use `deploy remote-test` (reboot recovers if lockout).
# Verify: sudo cscli metrics, sudo cscli decisions list, sudo cscli bouncers list
{
  config,
  lib,
  settings,
  ...
}:
let
  lanCidr = "${settings.network.address}/${toString settings.network.prefixLength}";
  lanNetwork =
    let
      parts = lib.splitString "." settings.network.address;
    in
    "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}.${builtins.elemAt parts 2}.0/${toString settings.network.prefixLength}";
in
{
  services.crowdsec = {
    enable = true;
    autoUpdateService = true;

    settings.general.api.server = {
      enable = true;
      listen_uri = "127.0.0.1:8080";
    };

    hub.collections = [
      "crowdsecurity/linux"
      "crowdsecurity/caddy"
      "crowdsecurity/http-cve"
    ];

    localConfig = {
      acquisitions = [
        {
          source = "journalctl";
          journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
          labels.type = "syslog";
        }
        {
          source = "journalctl";
          journalctl_filter = [ "_SYSTEMD_UNIT=caddy.service" ];
          labels.type = "caddy";
        }
      ];

      # Whitelist LAN, Tailscale, and loopback to prevent self-banning
      postOverflows.s01Whitelist = [
        {
          name = "crowdsecurity/local-whitelist";
          description = "Whitelist LAN, Tailscale, and loopback";
          whitelist = {
            reason = "local/vpn traffic - never ban";
            cidr = [
              lanNetwork
              "100.64.0.0/10"
              "127.0.0.0/8"
            ];
          };
        }
      ];
    };
  };

  services.crowdsec-firewall-bouncer = {
    enable = true;
    settings = {
      mode = "nftables";
      update_frequency = "10s";
      log_level = "info";
    };
  };

  # Caddy access logs to stdout so journald captures them for CrowdSec parsing
  services.caddy.globalConfig = lib.mkAfter ''
    log {
      output stderr
      format json
    }
  '';
}
