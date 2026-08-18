# Service module imports
# Enable/disable services by uncommenting their import lines.
# Service-specific configuration (ports, containers, etc.) lives in each module.
{
  imports = [
    ./services/cockpit.nix # Web-based system management
    ./services/tailscale.nix # Tailscale VPN (native)
    ./services/cloudflare.nix # Cloudflare DDNS (apex A/AAAA; not enough alone under CGNAT)
    ./services/cloudflared.nix # Cloudflare Tunnel (public HTTPS behind Starlink CGNAT)
    # ./services/remote-desktop.nix # XFCE + xrdp (unused)
    ./services/arr-suite.nix # Nixarr Sonarr+Radarr + RDT-Client (TorBox)
    # ./services/transmission.nix # Torrent client with VPN killswitch
    ./services/caddy.nix # Reverse proxy with automatic HTTPS
    ./services/adguard.nix # AdGuard Home DNS (port 53, web UI 3000) — enable after deploy
    ./services/filesharing.nix # NFS + Samba guest share of entire /media pool
    ./services/router.nix # Router: NAT + WiFi AP + DHCP — enable in settings.nix
    ./hermes/hermes.nix # Hermes Agent via hermes-pnp composer + host leftovers
  ];
}
