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

  # ENV_VAR_NAME = "sops_secret_key"
  # Add new OpenClaw secrets here — the template generates /run/openclaw.env automatically.
  # prettier-ignore
  openclawSecrets = {
    OPENCLAW_GATEWAY_TOKEN = "openclaw_gateway_token";
    OPENCLAW_GATEWAY_PASSWORD = "openclaw_gateway_password";
    XAI_API_KEY = "xai_api_key";
    OPENROUTER_API_KEY = "openrouter_api_key";
    OPENAI_API_KEY = "openrouter_api_key";
    ANTHROPIC_API_KEY = "anthropic_api_key";
    BRAVE_API_KEY = "brave_search_api_key";
    TELEGRAM_BOT_TOKEN = "telegram_bot_token";
    GOOGLE_PLACES_API_KEY = "google_places_api_key";
    BROWSERLESS_API_TOKEN = "browserless_api_token";
    MATON_API_KEY = "maton_api_key";
    HA_TOKEN = "ha_token";
    HA_URL = "ha_url";
    TELEGRAM_ADMIN_ID = "telegram_admin_id";
    GOOGLE_API_KEY = "google_api_key";
    GEMINI_API_KEY = "google_api_key";
    CLAWHUB_TOKEN = "clawhub_token";
    X_API_KEY = "x_api_key";
    X_API_SECRET = "x_api_secret";
    X_ACCESS_TOKEN = "x_access_token";
    X_ACCESS_SECRET = "x_access_secret";
    X_BEARER_TOKEN = "x_bearer_token";
  };
in
{
  services.openclaw.secretNames = lib.attrNames openclawSecrets;

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
        telegram_admin_id = { };
        cloudflare_dns_api_token = { };
        xai_api_key = { };
        filebrowser_password = { };
        crowdsec_bouncer_api_key = { };
        clawhub_token = { };
        x_api_key = { };
        x_api_secret = { };
        x_access_token = { };
        x_access_secret = { };
        x_bearer_token = { };
      }
      (lib.mkIf (settings.enableRouter or false) {
        wifi_ap_password = { };
      })
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

    templates = lib.mkMerge [
      {
        openclawEnv = {
          owner = "root";
          group = "root";
          mode = "0640";
          path = "/run/openclaw.env";
          content = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              envVar: sopsKey: ''${envVar}="${config.sops.placeholder.${sopsKey}}"''
            ) openclawSecrets
          );
        };
      }
      (lib.mkIf wifiEnabled {
        wifiEnv = {
          owner = "root";
          group = "root";
          mode = "0400";
          path = "/run/wifi.env";
          content = ''
            WIFI_PSK="${config.sops.placeholder."wifi_psk"}"
          '';
        };
      })
    ];
  };
}
