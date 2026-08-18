# ./services/cockpit.nix
{
  lib,
  settings,
  ...
}:

{
  services.cockpit = {
    enable = true;
    openFirewall = false;
    settings = {
      WebService = {
        Origins = lib.mkForce "https://cockpit.${settings.domain}";
        ProtocolHeader = "X-Forwarded-Proto";
        ForwardedForHeader = "X-Forwarded-For";
        AllowUnencrypted = true;
      };
    };
  };

  # Package unit listens on *:9090. Empty first entry clears that default.
  systemd.sockets.cockpit.listenStreams = lib.mkForce [
    ""
    "127.0.0.1:9090"
  ];

  services.caddy.proxyServices = {
    "cockpit.${settings.domain}" = 9090;
  };

  users.users.${settings.adminUser}.extraGroups = [ "podman" ];
}
