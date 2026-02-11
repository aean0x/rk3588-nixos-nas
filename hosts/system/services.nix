# Service module imports
# Enable/disable services by uncommenting their import lines.
# Service-specific configuration (ports, containers, etc.) lives in each module.
{
  imports = [
    # ./services/cockpit.nix      # Web-based system management (port 9090)
    ./services/containers.nix # Docker/Podman engine, ZFS storage, auto-pull/restart timers
    ./services/home-assistant.nix # Home Assistant, Matter Server, OTBR (Docker)
    ./services/tailscale.nix # Tailscale VPN (native)
    ./services/openclaw.nix # OpenClaw (native) — enable after secrets
    ./services/onedrive.nix # OneDrive sync for OpenClaw workspace
    # ./services/cloudflared.nix # Cloudflare tunnel — enable after tunnel creation
    ./services/remote-desktop.nix # XFCE + xrdp
    # ./services/arr-suite.nix    # Media stack (Sonarr, Radarr, Jellyfin, etc.)
    # ./services/transmission.nix # Torrent client with VPN killswitch
    ./services/caddy.nix # Reverse proxy with automatic HTTPS
    ./services/adguard.nix # AdGuard Home DNS (port 53, web UI 3000) — enable after deploy
    ./services/tasks.nix # Auto-upgrade and garbage collection
  ];
}
