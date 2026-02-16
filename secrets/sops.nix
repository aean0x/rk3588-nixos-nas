# SOPS secrets configuration
# Decrypted at runtime via sops-nix
{
  config,
  lib,
  settings,
  ...
}:
let
  wifiEnabled = settings.enableWifi or false;
in
{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = lib.mkMerge [
      {
        user_hashedPassword = { };
        tailscale_authKey = { };
        openclaw_gateway_token = { };
        openclaw_gateway_password = { };
        openrouter_api_key = { };
        google_api_key = { };
        anthropic_api_key = { };
        brave_search_api_key = { };
        telegram_bot_token = { };
        composio_encryption_key = { };
        composio_jwt_secret = { };
        google_workspace_client_id = { };
        google_workspace_client_secret = { };
        google_places_api_key = { };
        onedrive_rclone_config = {
          mode = "0444";
        };
        browserless_api_token = { };
        maton_api_key = { };
        ha_token = { };
        ha_url = { };
        cloudflare_dns_api_token = { };
        xai_api_key = { };
      }
      (lib.mkIf (config.users.users ? cloudflared) {
        cloudflared_tunnel_credentials = {
          owner = "cloudflared";
          group = "cloudflared";
        };
      })
      (lib.mkIf wifiEnabled {
        wifi_psk = { };
      })
    ];

    templates = lib.mkIf wifiEnabled {
      wifiEnv = {
        owner = "root";
        group = "root";
        mode = "0400";
        path = "/run/wifi.env";
        content = ''
          WIFI_PSK="${config.sops.placeholder."wifi_psk"}"
        '';
      };
    };
  };
}
