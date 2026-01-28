# Centralized SOPS configuration
# Import this module in hosts/system/default.nix
{ ... }:
{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # User secrets
      "user.hashedPassword" = { };
      "user.pubKey" = { };

      # VPN and service credentials
      "vpn.wgConf" = { };
      "services.transmission.credentials" = { };
      "services.caddy.cloudflareToken" = { };
    };
  };
}
