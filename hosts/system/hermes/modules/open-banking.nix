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
  # Pin so unit restarts do not float on origin/main.
  from = "git+https://github.com/open-banking-io/mcp-server.git@aa18c9c437a00f2b73f64e2d974663664d269ee2";
  python = pkgs.python3;
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
      python
    ];
    text = ''
      : "''${CREDENTIALS_DIRECTORY:?}"
      export FASTMCP_HOST=127.0.0.1
      export FASTMCP_PORT=${toString port}
      export FASTMCP_STREAMABLE_HTTP_PATH=/mcp
      # uv-managed CPython is python-build-standalone; PT_INTERP is
      # /lib/ld-linux-aarch64.so.1, which on NixOS is a musl stub-ld
      # (execve → EACCES / systemd 203/EXEC). Use nixpkgs CPython.
      export UV_PYTHON=${lib.getExe python}
      export UV_PYTHON_DOWNLOADS=never
      exec uvx --python "$UV_PYTHON" --from ${lib.escapeShellArg from} -- python ${serve}
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
        "UV_PYTHON_DOWNLOADS=never"
      ];
      MemoryMax = "512M";
      OOMScoreAdjust = 400;
      ProtectSystem = "strict";
      # ProtectSystem remounts writable StateDirectory noexec; uv wheels
      # (cryptography _rust.abi3.so) need PROT_EXEC.
      ExecPaths = [ "/var/lib/obi-mcp" ];
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
