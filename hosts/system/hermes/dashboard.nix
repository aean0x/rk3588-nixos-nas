# Hermes web dashboard — FastAPI/Uvicorn server running inside the container.
# The host-side hermes CLI (addToSystemPackages = true) routes the command into
# the container transparently, so the server process lives inside the container
# and the docker port mapping makes it reachable at host 127.0.0.1:9119.
# Caddy proxies hermes.<domain> → 127.0.0.1:9119 (LAN-only by default).
{ settings, ... }:
{
  systemd.services.hermes-dashboard = {
    description = "Hermes Agent web dashboard";
    # Container must be up before the dashboard can exec into it.
    after = [
      "network-online.target"
      "hermes-agent.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "hermes-agent.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      # Must run as a hostUser so docker exec routing works.
      User = settings.adminUser;
      # --host 0.0.0.0 --insecure: binds inside the container to all interfaces
      # so the docker port mapping (-p 127.0.0.1:9119:9119) reaches it from the host.
      # --tui: enables the in-browser Chat tab (requires pty extra).
      ExecStart = "/run/current-system/sw/bin/hermes dashboard --no-open --host 0.0.0.0 --insecure --port 9119 --tui";
      Restart = "on-failure";
      RestartSec = 15;
    };
  };

  # LAN-only by default (not in caddy.externalHosts).
  services.caddy.proxyServices."hermes.${settings.domain}" = 9119;
}
