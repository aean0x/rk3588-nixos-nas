# open-banking.io MCP via hermesPnP.mcpProxy.
# Upstream is stdio-only, so a loopback Streamable-HTTP sidecar holds the
# sops creds. Hermes only sees the proxy URL — keys stay off /run/hermes.env.
#
# MCP credential methods (env, never a bundle file):
#   OBI_CREDENTIALS  — path OR inline JSON (path would write/read a file)
#   OBI_API_KEY + OBI_PRIVATE_KEY + OBI_BASE_URL — split env (alternative)
# We take the split secrets from systemd LoadCredential (tmpfs, 0400) and
# construct the SDK client in-process. OBI_* are not exported, so they
# never land in the unit Environment= or /proc/pid/environ.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  port = 3141;
  from = "git+https://github.com/open-banking-io/mcp-server.git";
  serve = pkgs.writeText "obi-mcp-http.py" ''
    import os
    from pathlib import Path

    from open_banking_io import OpenBankingClient
    import obi_mcp.server as srv
    from obi_mcp.server import mcp

    cred = Path(os.environ["CREDENTIALS_DIRECTORY"])

    def _read(name: str) -> str:
        return (cred / name).read_text(encoding="utf-8").strip()

    srv._client = OpenBankingClient(
        api_base_url=_read("obi_base_url"),
        api_key=_read("obi_api_key"),
        private_key_pkcs8=_read("obi_private_key"),
    )
    mcp.run(transport="streamable-http")
  '';
  start = pkgs.writeShellApplication {
    name = "obi-mcp-http";
    runtimeInputs = [
      pkgs.uv
      pkgs.git
    ];
    text = ''
      : "''${CREDENTIALS_DIRECTORY:?}"
      export FASTMCP_HOST=127.0.0.1
      export FASTMCP_PORT=${toString port}
      export FASTMCP_STREAMABLE_HTTP_PATH=/mcp
      exec uvx --refresh --from ${lib.escapeShellArg from} -- python ${serve}
    '';
  };
in
{
  systemd.services.obi-mcp-http = {
    description = "open-banking.io MCP (Streamable HTTP, loopback)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "mcp-proxy.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe start;
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStartSec = 180;
      DynamicUser = true;
      StateDirectory = "obi-mcp";
      WorkingDirectory = "/var/lib/obi-mcp";
      LoadCredential = [
        "obi_api_key:${config.sops.secrets.obi_api_key.path}"
        "obi_private_key:${config.sops.secrets.obi_private_key.path}"
        "obi_base_url:${config.sops.secrets.obi_base_url.path}"
      ];
      Environment = [
        "HOME=/var/lib/obi-mcp"
        "UV_CACHE_DIR=/var/lib/obi-mcp/uv"
        "UV_PYTHON_INSTALL_DIR=/var/lib/obi-mcp/python"
      ];
      MemoryMax = "512M";
      OOMScoreAdjust = 400;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };

  systemd.services.mcp-proxy = {
    after = [ "obi-mcp-http.service" ];
    wants = [ "obi-mcp-http.service" ];
  };

  services.hermesPnP.mcpProxy.backends.open-banking-io = {
    upstream = "http://127.0.0.1:${toString port}/mcp";
  };

  services.hermes-agent.mcpServers.open-banking-io = {
    url = "http://127.0.0.1:3140/open-banking-io";
    connect_timeout = 180;
    timeout = 180;
  };
}
