# Tailscale VPN (native NixOS)
{
  config,
  ...
}:
{
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_authKey.path;
    openFirewall = true;
    extraUpFlags = [
      "--ssh"
      "--accept-routes"
      "--accept-dns"
      "--advertise-routes=192.168.1.0/24"
    ];
  };
}
