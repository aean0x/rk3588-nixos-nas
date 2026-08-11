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

  # Curated secrets for Hermes Agent.
  # Hermes reads these from $HERMES_HOME/.env at startup.
  # prettier-ignore
  hermesSecrets = {
    XAI_API_KEY = "xai_api_key";
    OPENROUTER_API_KEY = "openrouter_api_key";
    OPENAI_API_KEY = "openrouter_api_key";
    ANTHROPIC_API_KEY = "anthropic_api_key";
    BRAVE_API_KEY = "brave_search_api_key";
    # Hermes brave_free web backend reads BRAVE_SEARCH_API_KEY (not BRAVE_API_KEY).
    BRAVE_SEARCH_API_KEY = "brave_search_api_key";
    TELEGRAM_BOT_TOKEN = "telegram_bot_token";
    # Pre-authorizes the admin so the gateway allows access on first boot without DM pairing.
    TELEGRAM_ALLOWED_USERS = "telegram_admin_id";
    TELEGRAM_ADMIN_ID = "telegram_admin_id";
    GOOGLE_PLACES_API_KEY = "google_places_api_key";
    BROWSERLESS_API_TOKEN = "browserless_api_token";
    MATON_API_KEY = "maton_api_key";
    # Hermes Home Assistant toolset/platform expect HASS_* (not HA_*).
    HASS_TOKEN = "ha_token";
    HASS_URL = "ha_url";
    GOOGLE_API_KEY = "google_api_key";
    GEMINI_API_KEY = "google_api_key";
    CLAWHUB_TOKEN = "clawhub_token";
    X_API_KEY = "x_api_key";
    X_API_SECRET = "x_api_secret";
    X_ACCESS_TOKEN = "x_access_token";
    X_ACCESS_SECRET = "x_access_secret";
    X_BEARER_TOKEN = "x_bearer_token";
    GITHUB_PAT = "github_pat";
    BTC_WALLET_KEY = "btc_wallet_key";
    # GBrain embeddings (gbrain embed --stale / dream).
    ZEROENTROPY_API_KEY = "zeroentropy_api_key";
    # Firecrawl (Hermes web_extract / scrape backend).
    FIRECRAWL_API_KEY = "firecrawl_api_key";
    # Hermes OpenAI-compatible API server (loopback clients).
    # Distinct from OPENAI_API_KEY above (that one is OpenRouter for LLM routing).
    API_SERVER_KEY = "hermes_api_server_key";
    # Hermes WebUI / agent TTS (server-side ElevenLabs).
    ELEVENLABS_API_KEY = "elevenlabs_api_key";
    # Native DeepSeek provider (delegation/aux can use provider=deepseek).
    DEEPSEEK_API_KEY = "deepseek_api_key";
    COMPOSIO_API_KEY = "composio_api_key";
  };
in
{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = lib.mkMerge [
      {
        user_hashedPassword = { };
        tailscale_authKey = { };
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
        zeroentropy_api_key = { };
        firecrawl_api_key = { };
        filebrowser_password = { }; # legacy (filebrowser container commented out)
        # Arr / RDT-Client (also declared with modes in services/arr-suite.nix)
        torbox_api_key = { };
        rdtclient_username = { };
        rdtclient_password = { };
        crowdsec_bouncer_api_key = { };
        clawhub_token = { };
        x_api_key = { };
        x_api_secret = { };
        x_access_token = { };
        x_access_secret = { };
        x_bearer_token = { };
        github_pat = { };
        btc_wallet_key = { };
        # Shared bearer for Hermes API_SERVER_KEY (loopback OpenAI-compatible API).
        # Generate: openssl rand -hex 32
        hermes_api_server_key = { };
        # ElevenLabs TTS for Hermes WebUI (and agent when it uses the same env).
        elevenlabs_api_key = { };
        # Native DeepSeek API key → DEEPSEEK_API_KEY in /run/hermes.env.
        deepseek_api_key = { };
        composio_api_key = { };
        # Hermes → workstation agent SSH private key (/run/secrets/…).
        # Used only by ssh-workstation wrappers (IdentityFile). Do not copy into
        # hermes HOME — keep out of the model’s normal workspace tree.
        nix_pc_agent_ssh_key = {
          owner = "hermes";
          group = "hermes";
          mode = "0600";
        };
      }
      (lib.mkIf (settings.enableRouter or false) {
        wifi_ap_password = { };
      })
      # cloudflared uses DynamicUser + LoadCredential; root-owned secret is fine.
      # Declared when settings.cloudflareTunnelId is set (see services/cloudflared.nix).
      (lib.mkIf wifiEnabled {
        wifi_psk = { };
      })
    ];

    templates = lib.mkMerge [
      {
        hermesEnv = {
          owner = "hermes";
          group = "hermes";
          mode = "0640";
          path = "/run/hermes.env";
          # HERMES_MANAGED durable path for API server: secret + static knobs
          # land in ${stateDir}/.hermes/.env at activation (not `hermes config set`).
          content = lib.concatStringsSep "\n" (
            (lib.mapAttrsToList (
              envVar: sopsKey: "${envVar}=${config.sops.placeholder.${sopsKey}}"
            ) hermesSecrets)
            ++ [
              ""
              "# Hermes OpenAI-compatible API server (loopback clients)"
              "API_SERVER_ENABLED=true"
              "API_SERVER_HOST=127.0.0.1"
              "API_SERVER_PORT=8642"
              "API_SERVER_MODEL_NAME=hermes-agent"
            ]
          );
        };
        # Hermes WebUI process env (ELEVENLABS_API_KEY for server-side TTS).
        # Also mirrored into /run/hermes.env via hermesSecrets for HERMES_HOME/.env.
        hermesWebuiEnv = {
          owner = "hermes";
          group = "hermes";
          mode = "0400";
          path = "/run/hermes-webui.env";
          content = "ELEVENLABS_API_KEY=${config.sops.placeholder.elevenlabs_api_key}";
        };
      }
      (lib.mkIf wifiEnabled {
        wifiEnv = {
          owner = "root";
          group = "root";
          mode = "0400";
          path = "/run/wifi.env";
          content = "WIFI_PSK=${config.sops.placeholder."wifi_psk"}";
        };
      })
    ];
  };
}
