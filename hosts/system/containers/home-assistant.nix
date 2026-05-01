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
    "homeassistant.${settings.domain}" = haPort;
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
      networks = [ "host" ];
      capabilities = {
        NET_ADMIN = true;
        NET_RAW = true;
      };
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
      networks = [ "host" ];
      capabilities = {
        NET_ADMIN = true;
        NET_RAW = true;
      };
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
      networks = [ "host" ];
      privileged = true;
      capabilities = {
        NET_ADMIN = true;
        NET_RAW = true;
      };
      devices = [
        "${settings.threadRadioPath}:/dev/ttyACM0"
        "/dev/net/tun"
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
  # Pre-start: reverse proxy trust + HACS install/update
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

    # Install/update HACS to the host-mounted volume
    HACS_DIR=/var/lib/home-assistant/custom_components/hacs
    mkdir -p /var/lib/home-assistant/custom_components
    LATEST=$(${pkgs.curl}/bin/curl -sf https://api.github.com/repos/hacs/integration/releases/latest | ${pkgs.jq}/bin/jq -r .tag_name) || true
    if [ -n "$LATEST" ] && [ "$LATEST" != "null" ]; then
      ${pkgs.wget}/bin/wget -qO /tmp/hacs.zip \
        "https://github.com/hacs/integration/releases/download/$LATEST/hacs.zip"
      rm -rf "$HACS_DIR"
      ${pkgs.unzip}/bin/unzip -qo /tmp/hacs.zip -d "$HACS_DIR"
      rm -f /tmp/hacs.zip
      echo "HACS $LATEST installed"
    else
      echo "HACS update skipped (GitHub unreachable or no release found)"
    fi
  '';

  # ===================
  # Service ordering
  # ===================
  systemd.services.docker-otbr = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

}
