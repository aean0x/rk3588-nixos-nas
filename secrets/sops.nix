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
        composio_encryption_key = { };
        composio_jwt_secret = { };
        onedrive_rclone_config = {
          owner = "openclaw";
          group = "openclaw";
          mode = "0400";
        };
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
