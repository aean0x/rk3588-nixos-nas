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
  secrets = config.sops.secrets;
in
{
  # Wire OpenClaw env secrets from sops paths.
  # Key = env var name, value = decrypted secret file path.
  # Add new OpenClaw secrets here — the module generates the env file automatically.
  services.openclaw.envSecrets = {
    OPENCLAW_GATEWAY_TOKEN = secrets.openclaw_gateway_token.path;
    OPENCLAW_GATEWAY_PASSWORD = secrets.openclaw_gateway_password.path;
    XAI_API_KEY = secrets.xai_api_key.path;
    OPENROUTER_API_KEY = secrets.openrouter_api_key.path;
    OPENAI_API_KEY = secrets.openrouter_api_key.path;
    ANTHROPIC_API_KEY = secrets.anthropic_api_key.path;
    BRAVE_API_KEY = secrets.brave_search_api_key.path;
    TELEGRAM_BOT_TOKEN = secrets.telegram_bot_token.path;
    GOOGLE_PLACES_API_KEY = secrets.google_places_api_key.path;
    BROWSERLESS_API_TOKEN = secrets.browserless_api_token.path;
    MATON_API_KEY = secrets.maton_api_key.path;
    HA_TOKEN = secrets.ha_token.path;
    HA_URL = secrets.ha_url.path;
    TELEGRAM_ADMIN_ID = secrets.telegram_admin_id.path;
    GOOGLE_API_KEY = secrets.google_api_key.path;
    GEMINI_API_KEY = secrets.google_api_key.path;
    CLAWHUB_TOKEN = secrets.clawhub_token.path;
    X_API_KEY = secrets.x_api_key.path;
    X_API_SECRET = secrets.x_api_secret.path;
    X_ACCESS_TOKEN = secrets.x_access_token.path;
    X_ACCESS_SECRET = secrets.x_access_secret.path;
  };

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
        clawhub_token = { };
        x_api_key = { };
        x_api_secret = { };
        x_access_token = { };
        x_access_secret = { };
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
