# Home Assistant ecosystem: HA Core, Matter Server, OTBR (Docker)
{
  pkgs,
  settings,
  ...
}:
let
  haPort = 8123;
  matterPort = 5580;
  otbrPort = 8082;
  otbrRestPort = 8081;

  haImage = "ghcr.io/home-assistant/home-assistant:stable";
  matterImage = "ghcr.io/matter-js/matterjs-server:latest";
  otbrImage = "ghcr.io/ownbee/hass-otbr-docker:latest";
in
{
  services.caddy.proxyServices = {
    "ha.rocknas.local" = haPort;
  };

  virtualisation.oci-containers.containers = {
    # ===================
    # Home Assistant
    # ===================
    home-assistant = {
      image = haImage;
      volumes = [
        "/var/lib/home-assistant:/config"
        "/run/dbus:/run/dbus:ro"
      ];
      environment = {
        TZ = settings.timeZone;
        PYTHONDONTWRITEBYTECODE = "1";
      };
      extraOptions = [
        "--network=host"
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
      autoStart = true;
    };

    # ===================
    # Matter Server
    # ===================
    matter-server = {
      image = matterImage;
      volumes = [
        "/var/lib/matter-server:/data"
        "/run/dbus:/run/dbus:ro"
      ];
      environment = {
        LOG_LEVEL = "info";
      };
      extraOptions = [
        "--network=host"
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
      cmd = [
        "--storage-path"
        "/data"
        "--primary-interface"
        "${settings.network.interface}"
      ];
      autoStart = true;
    };

    # ===================
    # OpenThread Border Router (OTBR)
    # ===================
    otbr = {
      image = otbrImage;
      volumes = [
        "/var/lib/otbr:/data"
        "/run/dbus:/run/dbus:ro"
      ];
      environment = {
        DEVICE = "/dev/ttyACM0";
        BAUDRATE = "${toString settings.baudRate}";
        FLOW_CONTROL = "0";
        FIREWALL = "1";
        NAT64 = "1";
        OTBR_MDNS = "avahi";
        BACKBONE_IF = settings.network.interface;
        OT_LOG_LEVEL = "info";
        OT_WEB_PORT = "${toString otbrPort}";
        OT_REST_LISTEN_ADDR = "0.0.0.0";
        OT_REST_LISTEN_PORT = "${toString otbrRestPort}";
      };
      extraOptions = [
        "--network=host"
        "--privileged"
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
        "--device=${settings.threadRadioPath}:/dev/ttyACM0"
        "--device=/dev/net/tun"
      ];
      autoStart = true;
    };
  };

  # ===================
  # Kernel Sysctl (HA/OTBR networking)
  # ===================
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv4.conf.default.forwarding" = 1;
    "net.ipv6.conf.default.forwarding" = 1;
    "net.ipv6.conf.docker0.disable_ipv6" = 1;
    "net.ipv6.conf.all.accept_ra" = 2;
    "net.ipv6.conf.default.accept_ra" = 2;
    "net.ipv6.conf.${settings.network.interface}.accept_ra" = 2;
    "net.ipv6.conf.all.accept_ra_rt_info_max_plen" = 64;
  };

  # ===================
  # Firewall
  # ===================
  networking.firewall = {
    allowedTCPPorts = [
      haPort
      matterPort
      otbrPort
      otbrRestPort
    ];
    allowedUDPPorts = [
      5353 # mDNS
    ];
  };

  # ===================
  # Reverse proxy trust (Caddy on 127.0.0.1)
  # ===================
  systemd.services.docker-home-assistant.preStart = ''
        mkdir -p /var/lib/home-assistant
        cat > /var/lib/home-assistant/http.yaml <<'EOF'
    use_x_forwarded_for: true
    trusted_proxies:
      - "127.0.0.1"
      - "::1"
    EOF
        if ! grep -q 'http: !include http.yaml' /var/lib/home-assistant/configuration.yaml 2>/dev/null; then
          echo 'http: !include http.yaml' >> /var/lib/home-assistant/configuration.yaml
        fi
  '';

  # ===================
  # Service ordering
  # ===================
  systemd.services.docker-otbr = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # ===================
  # Refresh service (pull + restart)
  # ===================
  systemd.services.home-assistant-refresh = {
    description = "Pull latest Home Assistant ecosystem images and refresh containers";
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${pkgs.docker}/bin/docker pull ${haImage} || true
      ${pkgs.docker}/bin/docker pull ${matterImage} || true
      ${pkgs.docker}/bin/docker pull ${otbrImage} || true
      ${pkgs.docker}/bin/docker image prune -f
      ${pkgs.systemd}/bin/systemctl try-restart docker-home-assistant.service
      ${pkgs.systemd}/bin/systemctl try-restart docker-matter-server.service
      ${pkgs.systemd}/bin/systemctl try-restart docker-otbr.service
    '';
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
  };

  systemd.timers.home-assistant-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon 05:00:00";
      Persistent = true;
      RandomizedDelaySec = "3600";
    };
  };

}
