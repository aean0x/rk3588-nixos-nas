# Home Assistant ecosystem: HA Core, Matter Server, OTBR (Docker)
{
  settings,
  ...
}:
let
  haPort = 8123;
  matterPort = 5580;
  otbrPort = 8082;
  otbrRestPort = 8081;
in
{
  virtualisation.oci-containers.containers = {
    # ===================
    # Home Assistant
    # ===================
    home-assistant = {
      image = "ghcr.io/home-assistant/home-assistant:stable";
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
      image = "ghcr.io/matter-js/matterjs-server:latest";
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
      image = "ghcr.io/ownbee/hass-otbr-docker:latest";
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
  # Service ordering
  # ===================
  systemd.services.docker-otbr = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}
