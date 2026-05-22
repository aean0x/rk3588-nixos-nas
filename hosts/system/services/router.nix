# Router: NAT gateway, WiFi AP (hostapd), DHCP (dnsmasq), nftables firewall
# Turns the NAS into a full router. WAN = primary ethernet, LAN = bridge (AP + optional ports).
# DNS handled by AdGuard (port 53) — dnsmasq runs DHCP-only.
# IPv6: DHCPv6-PD requests a /56 from upstream, radvd advertises a /64 on LAN.
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
  apInterface = "wlP2p33s0"; # WiFi adapter for AP (2.4GHz)
  ap5gInterface = "ap5g";   # Virtual interface for 5GHz AP (created on same phy0)
  lanBridge = "br0"; # Bridge name (AP + any extra LAN ports)
  lanInterfaces = [ ]; # Extra ethernet ports to add to LAN bridge

  # -- WiFi AP --
  ssid = "SKYNET";
  channel = 6; # 2.4GHz
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
  wanTcpPorts = [
    22 # SSH
    80 # HTTP (Caddy redirect)
    443 # HTTPS (Caddy reverse proxy)
    30033 # TeamSpeak file transfer
  ];
  wanUdpPorts = [
    9987 # TeamSpeak voice
  ];

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

    # Disable Docker's iptables management — nftables handles forwarding and NAT.
    # This avoids Docker's chains being flushed on nftables reload during deploys.
    virtualisation.docker.extraOptions = "--iptables=false";
    systemd.services.docker.after = [ "nftables.service" ];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkForce 1;
      "net.ipv6.conf.all.forwarding" = lib.mkForce 1;
      "net.ipv6.conf.${lanBridge}.accept_ra" = 0;
    };

    # accept_ra must be set AFTER forwarding is enabled — the kernel resets
    # accept_ra=0 on all interfaces when forwarding is toggled.
    systemd.services.ipv6-accept-ra = {
      description = "Set accept_ra=2 on WAN after forwarding is enabled";
      after = [
        "systemd-sysctl.service"
        "network-pre.target"
      ];
      before = [
        "network.target"
        "dhcpcd.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo 2 > /proc/sys/net/ipv6/conf/${wanIf}/accept_ra
      '';
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
    # DHCPv6 Prefix Delegation (request /56 from Starlink, assign /64 to LAN)
    # ===================
    networking.dhcpcd.extraConfig = ''
      ipv6rs
      interface ${wanIf}
        ipv6rs
        iaid 1
        ia_pd 1 ${lanBridge}/0/64
    '';

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

      # nftables replaces both iptables NAT and the NixOS firewall
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
              iifname "docker0" accept
              ${lib.optionalString (
                allWanTcp != [ ]
              ) ''iifname "${wanIf}" tcp dport { ${fmtPorts allWanTcp} } accept''}
              ${lib.optionalString (
                allWanUdp != [ ]
              ) ''iifname "${wanIf}" udp dport { ${fmtPorts allWanUdp} } accept''}
              udp dport 67 accept
              iifname "${wanIf}" udp dport 546 accept
              ip protocol icmp accept
              ip6 nexthdr icmpv6 accept
            }
            chain forward {
              type filter hook forward priority 0; policy drop;
              ct state established,related accept
              iifname "${lanBridge}" oifname "${wanIf}" accept
              iifname "docker0" accept
              iifname "${wanIf}" oifname "${lanBridge}" ip6 nexthdr icmpv6 accept
              ${fwdRules}
            }
          }
          table ip nat {
            chain postrouting {
              type nat hook postrouting priority 100;
              oifname "${wanIf}" masquerade
              ip saddr 172.16.0.0/12 masquerade
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
        wifi4 = {
          enable = true;
          capabilities = [
            "LDPC"
            "HT40-"
            "HT40+"
            "SHORT-GI-20"
            "SHORT-GI-40"
            "TX-STBC"
            "RX-STBC1"
            "DSSS_CCK-40"
            "MAX-AMSDU-7935"
          ];
        };
        wifi5.enable = false;
        settings = {
          beacon_int = 100;
          uapsd_advertisement_enabled = 0;
          # Drop 802.11b rates (units: 100 kbps; 60=6Mbps). Any 802.11g/n/ax device is fine.
          supported_rates = "60 90 120 180 240 360 480 540";
          basic_rates = "60 120 240";
        };
        networks.${apInterface} = {
          inherit ssid;
          authentication = {
            mode = "wpa2-sha256";
            wpaPasswordFile = config.sops.secrets.wifi_ap_password.path;
          };
          settings = {
            # BSS-level options (hostapd_bss_config) — must not appear in radio settings
            bss_transition = 1;
            disassoc_low_ack = 1;
            ap_max_inactivity = 180;
          };
        };
      };
      radios.${ap5gInterface} = {
        band = "5g";
        channel = 149; # UNII-3, 30 dBm, no DFS required
        inherit countryCode;
        wifi4 = {
          enable = true;
          capabilities = [
            "LDPC"
            "HT40+"
            "SHORT-GI-20"
            "SHORT-GI-40"
            "TX-STBC"
            "RX-STBC1"
          ];
        };
        wifi5 = {
          enable = true;
          operatingChannelWidth = "80";
          capabilities = [
            "MAX-MPDU-11454"
            "RXLDPC"
            "SHORT-GI-80"
            "SHORT-GI-160"
            "TX-STBC-2BY1"
            "SU-BEAMFORMER"
            "SU-BEAMFORMEE"
            "MU-BEAMFORMEE"
            "RX-ANTENNA-PATTERN"
            "TX-ANTENNA-PATTERN"
            "MAX-A-MPDU-LEN-EXP7"
          ];
        };
        settings = {
          beacon_int = 100;
          # VHT80 center channel for primary 149 (block: 149 153 157 161 → center 155)
          vht_oper_centr_freq_seg0_idx = 155;
        };
        networks.${ap5gInterface} = {
          inherit ssid;
          authentication = {
            mode = "wpa2-sha256";
            wpaPasswordFile = config.sops.secrets.wifi_ap_password.path;
          };
          settings = {
            bss_transition = 1;
            disassoc_low_ack = 1;
            ap_max_inactivity = 180;
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

    # Creates the 5GHz virtual AP interface on phy0 (DBS: dual-band simultaneous).
    # Must run before hostapd — the module bindsTo the device unit for ap5g,
    # so hostapd won't start until this interface exists.
    #
    # MAC: a vif on the same phy inherits the parent's MAC by default. Joining two
    # netdevs with identical MACs into br0 fails ("Name not unique on network")
    # and hostapd segfaults trying to bring the interface up. Fix: derive a
    # locally-administered MAC by setting bit 1 of the first byte (00:.. → 02:..).
    # hostapd then uses this as the BSS BSSID automatically.
    systemd.services.ap5g-vif = {
      description = "Create 5GHz AP virtual interface (ap5g) on phy0";
      after = [ "hostapd-regdom.service" ];
      before = [ "hostapd.service" ];
      wantedBy = [ "hostapd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Zombie netdev cleanup: iw del alone leaves the rtnl entry → EEXIST on next add.
        # Order: down → ip link del → iw del, then wait for firmware vdev teardown.
        ${pkgs.iproute2}/bin/ip link set ${ap5gInterface} down 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip link del ${ap5gInterface} 2>/dev/null || true
        ${pkgs.iw}/bin/iw dev ${ap5gInterface} del 2>/dev/null || true
        sleep 1.5

        base_mac=$(cat /sys/class/net/${apInterface}/address)
        uniq_mac=$(echo "$base_mac" \
          | ${pkgs.gawk}/bin/awk -F: '{printf "02:%s:%s:%s:%s:%s\n",$2,$3,$4,$5,$6}')
        echo "ap5g-vif: parent=$base_mac vif=$uniq_mac"

        ${pkgs.iw}/bin/iw phy phy0 interface add ${ap5gInterface} type __ap addr "$uniq_mac"
        ${pkgs.iproute2}/bin/ip link set ${ap5gInterface} up
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

        join_iface() {
          local iface=$1
          for attempt in $(seq 1 10); do
            if $ip link set "$iface" master ${lanBridge} 2>/dev/null; then
              echo "Joined $iface to ${lanBridge} on attempt $attempt"
              return 0
            fi
            echo "Attempt $attempt: $iface not ready, retrying..."
            sleep 1
          done
          echo "Warning: could not join $iface to ${lanBridge} after 10 attempts"
        }

        join_iface ${apInterface}
        join_iface ${ap5gInterface}

        # Monitor: check every 5s, re-join any interface that drops off
        while true; do
          sleep 5
          for iface in ${apInterface} ${ap5gInterface}; do
            if ! $ip link show "$iface" 2>/dev/null | grep -q "master ${lanBridge}"; then
              echo "$iface dropped from ${lanBridge}, rejoining..."
              $ip link set "$iface" master ${lanBridge} || true
            fi
          done
        done
      '';
    };

    # ===================
    # AP Watchdog (multi-signal)
    # ===================
    # Silent firmware dead-radio: WCN7850 firmware loses its peer table due to a
    # TX-path race on client disconnect. hostapd stays running, nl80211 reports
    # ENABLED (the control plane lies), but the radio can't deliver traffic.
    # Observed: May 11 2026, ~02:44 — AP silently dead for 5.5 hours.
    #
    # Recovery path A — conjunction: ≥2 of sig1/sig2/sig3 on 2 consecutive cycles.
    # Recovery path B — sig4 alone: fires when all clients are gone for 60 min
    #   after the radio was previously populated, indicating the dead-radio state
    #   where sig1/sig2/sig3 are all silent (no TX → no peer errors; no clients →
    #   sig2 gated off; nl80211 lies → sig3 silent).
    #
    #   Signal 1 — kernel error flood: "dp_tx: failed to find the peer" fires at
    #     40–500/cycle during normal operation (always-on baseline). At threshold=5
    #     it is effectively constant; its role is to confirm sig2/sig3, not stand
    #     alone. It drops to 0 when the radio truly dies (no TX attempts).
    #
    #   Signal 2 — traffic stall: clients associated but <2 KB flowed over the
    #     cycle window. Will fire during deep-idle periods but cannot trigger
    #     recovery without a second signal confirming a fault.
    #
    #   Signal 3 — hostapd control state: hostapd_cli not reporting ENABLED.
    #     Catches actual hostapd crashes; note this WON'T fire for the silent
    #     firmware hang (nl80211 lies), so signals 1+2 are the primary pair.
    #
    #   Signal 4 — persistent zero-client streak: ≥120 consecutive cycles (60 min)
    #     with 0 associated clients, after at least one client was previously seen.
    #     Triggers recovery independently — catches dead radio when all clients
    #     have fallen off and sig1/sig2/sig3 are all silent.
    #
    # Recovery: interface bounce resets firmware peer state; hostapd restart
    # alone is insufficient (firmware state survives across restarts).
    systemd.services.ap-watchdog = {
      description = "AP silent dead-radio watchdog (multi-signal)";
      after = [ "hostapd.service" ];
      requires = [ "hostapd.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iproute2 pkgs.iw pkgs.hostapd pkgs.systemd pkgs.coreutils pkgs.gnugrep ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
      };
      script = ''
        iface="${apInterface}"
        cycle=30              # seconds per check cycle
        peer_err_min=5        # kernel error hits per cycle to flag signal 1
        stall_bytes=2000      # rx+tx bytes per cycle below which signal 2 fires
        zero_client_max=120   # consecutive zero-client cycles before sig4 (60 min)
        cooldown=120          # seconds before re-arming after recovery

        echo "ap-watchdog: monitoring $iface"

        fail_count=0
        has_had_clients=0
        zero_client_streak=0
        rx_prev=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        tx_prev=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)

        while true; do
          sleep $cycle

          # --- Signal 1: ath12k peer-table error flood ---
          since=$(date -d "-''${cycle} seconds" '+%Y-%m-%d %H:%M:%S')
          peer_errors=$(journalctl -k --since "$since" --no-pager -q 2>/dev/null \
            | grep -c "dp_tx: failed to find the peer" || true)

          # --- Signal 2: clients associated but traffic stalled ---
          rx_now=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
          tx_now=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
          delta=$(( (rx_now - rx_prev) + (tx_now - tx_prev) ))
          rx_prev=$rx_now; tx_prev=$tx_now
          clients=$(iw dev $iface station dump 2>/dev/null | grep -c "^Station" || true)

          # --- Signal 3: hostapd not reporting ENABLED ---
          hostapd_enabled=$(hostapd_cli -p /run/hostapd status 2>/dev/null \
            | grep -c "state=ENABLED" || true)

          # --- Signal 4: persistent zero-client streak after previous association ---
          if [ "$clients" -gt 0 ]; then
            has_had_clients=1
            zero_client_streak=0
          elif [ "$has_had_clients" -eq 1 ]; then
            zero_client_streak=$((zero_client_streak + 1))
          fi

          signals=0
          [ "$peer_errors" -ge "$peer_err_min" ] \
            && signals=$((signals + 1)) \
            && echo "ap-watchdog: sig1 kernel errors=$peer_errors"
          [ "$clients" -gt 0 ] && [ "$delta" -lt "$stall_bytes" ] \
            && signals=$((signals + 1)) \
            && echo "ap-watchdog: sig2 traffic stall delta=''${delta}B clients=$clients"
          [ "$hostapd_enabled" -eq 0 ] \
            && signals=$((signals + 1)) \
            && echo "ap-watchdog: sig3 hostapd not ENABLED"

          sig4=0
          [ "$zero_client_streak" -ge "$zero_client_max" ] \
            && sig4=1 \
            && echo "ap-watchdog: sig4 zero-client streak=''${zero_client_streak} cycles (~$((zero_client_streak / 2)) min)"

          if [ "$signals" -ge 2 ] || [ "$sig4" -eq 1 ]; then
            fail_count=$((fail_count + 1))
            echo "ap-watchdog: signals=$signals sig4=$sig4 fail_count=$fail_count"
            if [ "$fail_count" -ge 2 ]; then
              echo "ap-watchdog: confirmed dead-radio — recovering $iface"
              ${pkgs.iproute2}/bin/ip link set "$iface" down || true
              sleep 2
              ${pkgs.iproute2}/bin/ip link set "$iface" up   || true
              sleep 2
              systemctl restart hostapd || true
              echo "ap-watchdog: recovery done, cooling down ''${cooldown}s"
              fail_count=0
              zero_client_streak=0
              sleep $cooldown
              rx_prev=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
              tx_prev=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
            fi
          else
            fail_count=0
          fi
        done
      '';
    };

    # ===================
    # IPv6 Router Advertisements (radvd)
    # Advertises delegated prefix from DHCPv6-PD to LAN clients via SLAAC.
    # ::/64 auto-discovers whatever prefix dhcpcd assigned to br0.
    # ===================
    services.radvd = {
      enable = true;
      config = ''
        interface ${lanBridge} {
          AdvSendAdvert on;
          AdvManagedFlag off;
          AdvOtherConfigFlag off;
          prefix ::/64 {
            AdvOnLink on;
            AdvAutonomous on;
          };
        };
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
