# CrowdSec IDS/IPS: Docker engine + native nftables firewall bouncer
# Engine runs in container (reads host journald), bouncer runs native (needs host nftables).
# LAPI on 127.0.0.1:8180 (8080 taken by otbr-web).
#
# First-time setup after deploy:
#   docker exec crowdsec cscli bouncers add firewall-bouncer
#   # Add printed key to secrets/secrets.yaml as crowdsec_bouncer_api_key
#   deploy remote-switch
#
# Verify: docker exec crowdsec cscli metrics
#         docker exec crowdsec cscli decisions list
#         sudo cscli bouncers list (native bouncer)
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  lapiPort = 8180;
  configDir = "/var/lib/crowdsec/config";
  dataDir = "/var/lib/crowdsec/data";

  lanNetwork =
    let
      parts = lib.splitString "." settings.network.address;
    in
    "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}.${builtins.elemAt parts 2}.0/${toString settings.network.prefixLength}";

  # LAPI listen override (default 8080 conflicts with otbr-web)
  configLocal = pkgs.writeText "config.yaml.local" ''
    api:
      server:
        listen_uri: 127.0.0.1:${toString lapiPort}
  '';

  acquis = pkgs.writeText "acquis.yaml" ''
    source: journalctl
    journalctl_filter:
      - "_SYSTEMD_UNIT=sshd.service"
    labels:
      type: syslog
    ---
    source: journalctl
    journalctl_filter:
      - "_SYSTEMD_UNIT=caddy.service"
    labels:
      type: caddy
  '';

  whitelist = pkgs.writeText "local-whitelist.yaml" ''
    name: local-networks/whitelist
    description: "Ignore LAN, Tailscale, and loopback"
    filter: "1 == 1"
    whitelist:
      reason: "trusted local CIDRs"
      cidr:
        - ${lanNetwork}
        - 100.64.0.0/10
        - 127.0.0.0/8
  '';
in
{
  # ── CrowdSec engine container ──────────────────────────────
  virtualisation.oci-containers.containers.crowdsec = {
    image = "crowdsecurity/crowdsec:latest-debian";
    environment = {
      COLLECTIONS = "crowdsecurity/linux crowdsecurity/caddy crowdsecurity/http-cve";
    };
    volumes = [
      "/var/log/journal:/run/log/journal:ro"
      "/etc/machine-id:/etc/machine-id:ro"
      "${configDir}:/etc/crowdsec"
      "${dataDir}:/var/lib/crowdsec/data"
    ];
    extraOptions = [
      "--network=host"
      "--group-add=${toString config.users.groups.systemd-journal.gid}"
    ];
    autoStart = true;
  };

  # Deploy static config files before container starts
  systemd.services.docker-crowdsec.preStart = ''
    mkdir -p ${configDir}/acquis.d ${configDir}/postoverflows/s01-whitelist ${dataDir}
    cp -f ${configLocal} ${configDir}/config.yaml.local
    cp -f ${acquis} ${configDir}/acquis.d/sshd-caddy.yaml
    cp -f ${whitelist} ${configDir}/postoverflows/s01-whitelist/local-cidrs.yaml
  '';

  # ── Native nftables firewall bouncer ───────────────────────
  services.crowdsec-firewall-bouncer = {
    enable = true;
    registerBouncer.enable = false;
    secrets.apiKeyPath = config.sops.secrets.crowdsec_bouncer_api_key.path;
    settings = {
      mode = "nftables";
      api_url = "http://127.0.0.1:${toString lapiPort}/";
      update_frequency = "10s";
      log_level = "info";
      nftables = {
        ipv4 = {
          enabled = true;
          set-only = false;
          table = "crowdsec";
          chain = "crowdsec-chain";
        };
        ipv6 = {
          enabled = true;
          set-only = false;
          table = "crowdsec6";
          chain = "crowdsec6-chain";
        };
      };
    };
  };

  # Bouncer must wait for container LAPI to be listening.
  # Container takes ~15s to initialize on first boot; restart on failure handles the race.
  systemd.services.crowdsec-firewall-bouncer = {
    after = [ "docker-crowdsec.service" ];
    wants = [ "docker-crowdsec.service" ];
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "10s";
    };
  };

  # Caddy access logs to stderr so journald captures them for CrowdSec parsing
  services.caddy.globalConfig = lib.mkAfter ''
    log {
      output stderr
      format json
    }
  '';
}
