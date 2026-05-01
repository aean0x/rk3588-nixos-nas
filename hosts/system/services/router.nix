# Router: NAT gateway, WiFi AP (hostapd), DHCP (dnsmasq), nftables firewall
# Turns the NAS into a full router. WAN = primary ethernet, LAN = bridge (AP + optional ports).
# DNS handled by AdGuard (port 53) — dnsmasq runs DHCP-only.
#
# Enable: set enableRouter = true in settings.nix
# WiFi AP password: add wifi_ap_password to secrets/secrets.yaml
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  enabled = settings.enableRouter or false;

  # ===========================================================================
  # Router Configuration — edit these values to customize your network
  # ===========================================================================

  # -- Interfaces --
  wanIf = settings.network.interface; # Uplink to ISP
  apInterface = "wlP2p33s0"; # WiFi adapter for AP
  lanBridge = "br0"; # Bridge name (AP + any extra LAN ports)
  lanInterfaces = [ ]; # Extra ethernet ports to add to LAN bridge

  # -- WiFi AP --
  ssid = "SKYNET";
  channel = 6; # 2.4GHz — 5GHz works but 14dBm TX power limits range
  countryCode = "US";

  # -- LAN subnet --
  lanAddress = "192.168.2.1";
  lanPrefix = 24;
  dhcpStart = "192.168.2.10";
  dhcpEnd = "192.168.2.250";
  leaseTime = "12h";

  # -- Static DHCP leases --
  # Assign fixed IPs to known devices by MAC address.
  # Format: "mac-address,hostname,ip"
  staticLeases = [
    # "aa:bb:cc:dd:ee:ff,living-room-tv,192.168.2.10"
    # "11:22:33:44:55:66,office-printer,192.168.2.11"
  ];

  # -- Port forwarding (DNAT) --
  # Forward external ports to LAN devices. Used for game servers, cameras, etc.
  # { proto = "tcp"|"udp"; port = 25565; dest = "192.168.2.10"; }
  portForwards = [
    # { proto = "tcp"; port = 25565; dest = "192.168.2.10"; } # Minecraft
    # { proto = "udp"; port = 9987;  dest = "192.168.2.10"; } # TeamSpeak voice
  ];

  # -- WAN firewall --
  # Ports open on the WAN side (in addition to port forwards above).
  wanTcpPorts = [ 22 ]; # SSH
  wanUdpPorts = [ ];

  # -- Mesh / additional APs --
  # For WiFi mesh nodes (separate devices running hostapd):
  # 1. Flash them with NixOS or OpenWrt
  # 2. Connect their ethernet to a LAN port on this router
  # 3. Configure them as a bridge AP on the same subnet (192.168.2.0/24)
  # 4. Same SSID + password = seamless roaming (802.11r optional)
  # No config changes needed here — DHCP and DNS are centralized on this router.
  # Mesh nodes are just bridges; they don't need NAT or DHCP.

  # ===========================================================================
  # Derived values (don't edit below unless extending functionality)
  # ===========================================================================

  dhcpRange = "${dhcpStart},${dhcpEnd},${leaseTime}";

  fmtPorts = ports: lib.concatStringsSep ", " (map toString ports);

  # Collect all forwarded ports so they're also opened in the WAN firewall
  fwdTcpPorts = map (f: f.port) (builtins.filter (f: f.proto == "tcp") portForwards);
  fwdUdpPorts = map (f: f.port) (builtins.filter (f: f.proto == "udp") portForwards);
  allWanTcp = wanTcpPorts ++ fwdTcpPorts;
  allWanUdp = wanUdpPorts ++ fwdUdpPorts;

  # Generate nftables DNAT rules for port forwards
  dnatRules = lib.concatStringsSep "\n" (
    map (f: "${f.proto} dport ${toString f.port} dnat to ${f.dest}") portForwards
  );

  fwdRules = lib.concatStringsSep "\n" (
    map (f: ''iifname "${wanIf}" ${f.proto} dport ${toString f.port} ct state new accept'') portForwards
  );
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = !(settings.enableWifi or false);
        message = "Router AP mode conflicts with WiFi client mode. Set enableWifi = false in settings.nix.";
      }
    ];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkForce 1;
    };

    # ===================
    # Hardware/Regulatory
    # ===================
    hardware.wirelessRegulatoryDatabase = true;

    # ===================
    # WAN (DHCP from upstream / Starlink bypass)
    # ===================
    networking.interfaces.${wanIf} = {
      useDHCP = true;
      ipv4.routes = [
        {
          # Starlink dish management UI (bypass mode moves dish to 192.168.100.1)
          address = "192.168.100.0";
          prefixLength = 24;
        }
      ];
    };

    # ===================
    # Bridge (LAN side)
    # ===================
    networking = {
      bridges.${lanBridge}.interfaces = lanInterfaces;
      interfaces.${lanBridge}.ipv4.addresses = [
        {
          address = lanAddress;
          prefixLength = lanPrefix;
        }
      ];

      nat = {
        enable = true;
        externalInterface = wanIf;
        internalInterfaces = [ lanBridge ];
      };

      # nftables replaces iptables-based firewall
      firewall.enable = lib.mkForce false;
      nftables = {
        enable = true;
        ruleset = ''
          table inet filter {
            chain input {
              type filter hook input priority 0; policy drop;
              iif lo accept
              ct state established,related accept
              iifname "${lanBridge}" accept
              ${lib.optionalString (
                allWanTcp != [ ]
              ) ''iifname "${wanIf}" tcp dport { ${fmtPorts allWanTcp} } accept''}
              ${lib.optionalString (
                allWanUdp != [ ]
              ) ''iifname "${wanIf}" udp dport { ${fmtPorts allWanUdp} } accept''}
              udp dport 67 accept
              ip protocol icmp accept
            }
            chain forward {
              type filter hook forward priority 0; policy drop;
              ct state established,related accept
              iifname "${lanBridge}" oifname "${wanIf}" accept
              ${fwdRules}
            }
          }
          table ip nat {
            chain postrouting {
              type nat hook postrouting priority 100;
              oifname "${wanIf}" masquerade
            }
            ${lib.optionalString (portForwards != [ ]) ''
              chain prerouting {
                type nat hook prerouting priority -100;
                iifname "${wanIf}" ${dnatRules}
              }
            ''}
          }
        '';
      };
    };

    # ===================
    # WiFi AP (hostapd)
    # ===================
    services.hostapd = {
      enable = true;
      radios.${apInterface} = {
        band = "2g";
        inherit channel countryCode;
        wifi4.enable = true;
        wifi5.enable = false;
        settings = {
          ieee80211d = true;
          ieee80211h = true;
        };
        networks.${apInterface} = {
          inherit ssid;
          authentication = {
            mode = "wpa2-sha256";
            wpaPasswordFile = config.sops.secrets.wifi_ap_password.path;
          };
        };
      };
    };

    # Passive scan triggers firmware 11d regdom transition (country 00 → US)
    # Required for ath12k self-managed chips to unlock 5GHz AP channels
    systemd.services.hostapd-regdom = {
      description = "Trigger ath12k regulatory domain transition via passive scan";
      before = [ "hostapd.service" ];
      wantedBy = [ "hostapd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.iproute2}/bin/ip link set ${apInterface} up
        ${pkgs.iw}/bin/iw dev ${apInterface} scan passive 2>/dev/null || true
        sleep 3
        ${pkgs.iw}/bin/iw reg set ${countryCode}
        sleep 1
      '';
    };

    # Keeps the WiFi AP interface joined to the LAN bridge.
    # Runs as a persistent monitor — re-joins if the interface gets kicked out
    # (e.g. after network-addresses restart during config activation).
    systemd.services.hostapd-bridge = {
      description = "Keep WiFi AP interface joined to LAN bridge";
      after = [
        "hostapd.service"
        "sys-devices-virtual-net-${lanBridge}.device"
      ];
      requires = [ "hostapd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
      };
      script = ''
        ip="${pkgs.iproute2}/bin/ip"

        # Initial join with retries
        for attempt in $(seq 1 10); do
          if $ip link set ${apInterface} master ${lanBridge} 2>/dev/null; then
            echo "Joined ${apInterface} to ${lanBridge} on attempt $attempt"
            break
          fi
          echo "Attempt $attempt failed, retrying in 1s..."
          sleep 1
        done

        # Monitor: check every 5s, re-join if dropped
        while true; do
          sleep 5
          if ! $ip link show ${apInterface} 2>/dev/null | grep -q "master ${lanBridge}"; then
            echo "${apInterface} dropped from ${lanBridge}, rejoining..."
            $ip link set ${apInterface} master ${lanBridge} || true
          fi
        done
      '';
    };

    # ===================
    # DHCP (dnsmasq, DNS disabled — AdGuard handles port 53)
    # ===================
    services.dnsmasq = {
      enable = true;
      settings = {
        port = 0;
        interface = lanBridge;
        bind-interfaces = true;
        dhcp-range = dhcpRange;
        dhcp-option = [
          "3,${lanAddress}" # Gateway
          "6,${lanAddress}" # DNS (AdGuard)
        ];
        dhcp-host = staticLeases;
        dhcp-authoritative = true;
        log-dhcp = true;
      };
    };
  };
}
