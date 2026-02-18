# Service module imports
# Enable/disable services by uncommenting their import lines.
# Service-specific configuration (ports, containers, etc.) lives in each module.
{
  imports = [
    # ./services/cockpit.nix      # Web-based system management (port 9090)
    ./services/tailscale.nix # Tailscale VPN (native)
    # ./services/cloudflared.nix # Cloudflare tunnel — enable after tunnel creation
    ./services/remote-desktop.nix # XFCE + xrdp
    # ./services/arr-suite.nix    # Media stack (Sonarr, Radarr, Jellyfin, etc.)
    # ./services/transmission.nix # Torrent client with VPN killswitch
    ./services/caddy.nix # Reverse proxy with automatic HTTPS
    ./services/adguard.nix # AdGuard Home DNS (port 53, web UI 3000) — enable after deploy
  ];
}
