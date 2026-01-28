# Media server suite (Sonarr, Radarr, Lidarr, Prowlarr, Jellyfin, Jellyseerr)
# Transmission config is in transmission.nix
{ config, settings, ... }:

{
  nixarr = {
    enable = true;

    # Media directories managed by nixarr
    # Default: /data/media for media, /data/.state/nixarr for state
    mediaUsers = [ settings.adminUser ];

    # VPN configuration for Transmission killswitch
    vpn = {
      enable = true;
      # WireGuard config from your VPN provider - must exist before rebuild
      # Get this file from your VPN provider (Mullvad, AirVPN, etc.)
      wgConf = config.sops.secrets."vpn.wgConf".path;
    };

    # Sonarr - TV show management
    sonarr = {
      enable = true;
      openFirewall = true;
    };

    # Radarr - Movie management
    radarr = {
      enable = true;
      openFirewall = true;
    };

    # Lidarr - Music management
    lidarr = {
      enable = true;
      openFirewall = true;
    };

    # Prowlarr - Indexer manager for *arrs
    prowlarr = {
      enable = true;
      openFirewall = true;
    };

    # Jellyfin - Media streaming server
    jellyfin = {
      enable = true;
      openFirewall = true;
    };

    # Jellyseerr - Request management for Jellyfin
    jellyseerr = {
      enable = true;
      openFirewall = true;
    };
  };
}
