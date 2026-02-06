# Centralized SOPS configuration
# Import this module in hosts/system/default.nix
{ ... }:
{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # User secrets
      user_hashedPassword = { };

      # VPN and service credentials
      vpn_wgConf = { };
      services_transmission_credentials = { };
      services_caddy_cloudflareToken = { };
    };
  };
}
