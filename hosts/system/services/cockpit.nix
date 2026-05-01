# ./services/cockpit.nix
{
  lib,
  settings,
  ...
}:

{
  services.cockpit = {
    enable = true;
    openFirewall = true;
    settings = {
      WebService = {
        Origins = lib.mkForce "https://cockpit.${settings.domain}";
        ProtocolHeader = "X-Forwarded-Proto";
        ForwardedForHeader = "X-Forwarded-For";
        AllowUnencrypted = true;
      };
    };
  };

  services.caddy.proxyServices = {
    "cockpit.${settings.domain}" = 9090;
  };

  users.users.${settings.adminUser}.extraGroups = [ "podman" ];
}
