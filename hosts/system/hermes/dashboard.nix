# Hermes web dashboard — FastAPI/Uvicorn via host CLI routing into the container.
# The official hermes-agent module hardcodes --network=host for the container, so
# the dashboard process binds on the host network namespace (no docker -p publish).
# Caddy proxies hermes.<domain> → :9119 on the host (LAN-only by default).
{ settings, config, ... }:
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
      # Run as the hermes service user: it owns ~/.hermes/.env (the CLI reads this at
      # startup before exec-ing into the container) and needs docker group for docker exec.
      # adminUser cannot read .env — the hermes process rewrites it at 0600 at runtime.
      User = "hermes";
      # Systemd's default PATH omits /run/current-system/sw/bin; hermes needs docker on PATH.
      Environment = [ "PATH=${config.virtualisation.docker.package}/bin:/run/current-system/sw/bin:/run/wrappers/bin" ];
      # Loopback only: hermes-agent ≥0.20 refuses unauthenticated non-loopback
      # binds (even with --insecure). Caddy proxies hermes.<domain> → 127.0.0.1:9119.
      # --tui: in-browser Chat tab (ptyprocess is core; no separate pty extra).
      ExecStart = "/run/current-system/sw/bin/hermes dashboard --no-open --host 127.0.0.1 --port 9119 --tui";
      Restart = "on-failure";
      RestartSec = 15;
    };
  };

  # LAN-only by default (not in caddy.externalHosts).
  # Host rewrite: dashboard binds 127.0.0.1 and rejects Host: hermes.<domain>
  # (GHSA-ppp5-vxwm-4cf7). Caddy presents the loopback Host to the backend.
  services.caddy.proxyServices."hermes.${settings.domain}" = 9119;
  services.caddy.proxyUpstreamHost."hermes.${settings.domain}" = "127.0.0.1:9119";
}
