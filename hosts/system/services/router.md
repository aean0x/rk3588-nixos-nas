# Router Cheat Sheet

Interface names: WAN=`enP4p65s0`, LAN bridge=`br0`, WiFi AP=`wlP2p33s0`

---

## Status at a glance

```sh
# IP addresses on all interfaces
ip addr show

# Routing table
ip route show

# Connected WiFi clients
iw dev wlP2p33s0 station dump

# Active DHCP leases
cat /var/lib/dnsmasq/dnsmasq.leases

# ARP table (IP → MAC on LAN)
ip neigh show dev br0

# nftables ruleset (live)
nft list ruleset
```

---

## Services

```sh
systemctl status hostapd hostapd-bridge ap-watchdog hostapd-regdom
systemctl status dnsmasq radvd dhcpcd

# Restart AP cleanly (bounces interface + hostapd)
systemctl restart hostapd

# Restart watchdog after config change
systemctl restart ap-watchdog

# Check if watchdog ever triggered a recovery
journalctl -u ap-watchdog | grep "confirmed dead-radio"
```

---

## WiFi / hostapd

```sh
# AP operational state (ENABLED = good, nl80211 can lie on dead radio)
hostapd_cli -p /run/hostapd status

# List associated stations via hostapd
hostapd_cli -p /run/hostapd all_sta

# Kick a client by MAC
hostapd_cli -p /run/hostapd deauthenticate aa:bb:cc:dd:ee:ff

# Current regulatory domain (expect country=US after regdom service runs)
iw reg get

# Interface capabilities / frequency list
iw phy phy0 info | grep -A5 "Band 1"

# Per-client signal, bitrate, TX/RX stats
iw dev wlP2p33s0 station dump
```

---

## NAT / firewall (nftables)

```sh
# Live ruleset
nft list ruleset

# Show NAT table
nft list table ip nat

# Packet/byte counters per chain
nft list chain inet filter input
nft list chain inet filter forward

# Reload rules (NixOS manages this; manual use only)
systemctl reload nftables

# Test if masquerade is working
ip netns                          # (no netns needed — check from a LAN client)
curl -s ifconfig.me               # run on a LAN client, should show WAN IP
```

---

## DHCP (dnsmasq)

```sh
# Live leases
cat /var/lib/dnsmasq/dnsmasq.leases

# DHCP log stream
journalctl -u dnsmasq -f

# Force a client to renew (from the client)
dhclient -r && dhclient
```

---

## IPv6

```sh
# DHCPv6-PD status (prefix delegated by Starlink)
journalctl -u dhcpcd | grep -i "prefix\|pd\|ia_pd"

# Delegated prefix assigned to br0
ip -6 addr show dev br0

# Router advertisements being sent (radvd)
systemctl status radvd
journalctl -u radvd -n 50

# accept_ra value on WAN (should be 2 when forwarding=1)
cat /proc/sys/net/ipv6/conf/enP4p65s0/accept_ra

# Check a client received a SLAAC address
# (run on client) ip -6 addr show | grep "scope global"

# IPv6 routing table
ip -6 route show
```

---

## Traffic / throughput

```sh
# Interface byte counters (delta = throughput since last read)
cat /sys/class/net/br0/statistics/rx_bytes
cat /sys/class/net/enP4p65s0/statistics/tx_bytes

# Live per-interface throughput (1s updates)
watch -n1 'ip -s link show enP4p65s0; ip -s link show br0; ip -s link show wlP2p33s0'

# Connections through NAT
nft list table ip nat
conntrack -L 2>/dev/null | head -20   # requires conntrack-tools
```

---

## Diagnostics

```sh
# Kernel WiFi errors (ath12k peer-table race — normal baseline 40–200/30s)
journalctl -k | grep "dp_tx: failed to find the peer" | tail -20

# Count errors in last 60s (>500 sustained = abnormal)
journalctl -k --since "60 seconds ago" -q | grep -c "dp_tx: failed to find the peer"

# Bridge membership (wlP2p33s0 should show master br0)
ip link show wlP2p33s0
bridge link show

# DNS resolution from router (AdGuard on br0:53)
dig @192.168.2.1 example.com

# Trace a packet path
traceroute 8.8.8.8

# Ping WAN gateway
ping -c3 -I enP4p65s0 $(ip route show dev enP4p65s0 | awk '/default/{print $3}')
```

---

## Known quirks

- **`dp_tx: failed to find the peer`** — WCN7850 firmware artifact, fires 40–500 per 30s during normal operation. Not actionable. The ap-watchdog uses it only as a conjunction signal.
- **ap-watchdog sig4** — if the AP has been dead and all clients gone for 60 min, the watchdog forces an interface bounce + hostapd restart. Check `journalctl -u ap-watchdog` to see if this fired.
- **accept_ra reset** — when `net.ipv6.conf.all.forwarding=1` is set at boot, the kernel resets `accept_ra` to 0 on all interfaces. The `ipv6-accept-ra` service re-applies `accept_ra=2` on WAN after boot; if IPv6 stops working check `cat /proc/sys/net/ipv6/conf/enP4p65s0/accept_ra`.
- **Bridge join race** — hostapd-bridge retries joining `wlP2p33s0` to `br0` up to 10 times at 1s intervals, then monitors every 5s. If a client can associate but gets no DHCP, check `bridge link show`.
- **Starlink dish UI** — accessible at `192.168.100.0/24` when in bypass mode (route is statically set on WAN interface).
