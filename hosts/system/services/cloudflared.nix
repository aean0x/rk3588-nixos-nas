# Cloudflared tunnel (native NixOS)
# Setup: cloudflared tunnel create rocknas
# Then add the credentials JSON to secrets/secrets.yaml as cloudflared_tunnel_credentials
{
  config,
  ...
}:
let
  # Replace with your tunnel UUID after running: cloudflared tunnel create rocknas
  tunnelId = "00000000-0000-0000-0000-000000000000";
  # Replace with your Cloudflare domain
  domain = "example.com";
in
{
  # Ensure credentials file is owned by cloudflared
  sops.secrets.cloudflared_tunnel_credentials = {
    owner = "cloudflared";
    group = "cloudflared";
  };

  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = config.sops.secrets.cloudflared_tunnel_credentials.path;
      default = "http_status:404";
      ingress = {
        "ha.${domain}" = "http://localhost:8123";
        # "nas.${domain}" = "http://localhost:9090";
      };
    };
  };
}
