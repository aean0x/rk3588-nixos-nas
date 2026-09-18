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
#
# The feed is demand-only: the provider cannot refresh it (the bank session uid
# is sealed under the account private key, which it cannot read) and the MCP
# surface is read-only, so `last_synced_at` froze until a human opened the app.
# `obi-mcp-sync` is the daily AIS refresh that closes that gap — same
# LoadCredential secrets, same SDK, `sync_all()`. Read-only on the bank side:
# no consent renewal, no payment initiation, no state beyond its own directory.
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
    # FastMCP("open-banking-io") passes host/port kwargs, which beat FASTMCP_* env.
    mcp.settings.host = "127.0.0.1"
    mcp.settings.port = ${toString port}
    mcp.settings.streamable_http_path = "/mcp"
    mcp.run(transport="streamable-http")
  '';
  # Prints connection metadata only. The SDK never logs headers (the API key)
  # or bodies (ciphertext / decrypted data), and this script adds nothing else.
  sync = pkgs.writeText "obi-mcp-sync.py" ''
    # Daily authorized AIS refresh: syncs every account that still has an active
    # session, then reports which connections advanced and which did not.
    import datetime as dt
    import os
    import sys
    from pathlib import Path

    from open_banking_io import OpenBankingClient

    cred = Path(os.environ["CREDENTIALS_DIRECTORY"])


    def _read(name: str) -> str:
        return (cred / name).read_text(encoding="utf-8").strip()


    def _stamp(value: dt.datetime | None) -> str:
        if value is None:
            return "never"
        return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds")


    def _report(connections: list) -> dict:
        seen = {}
        for i, c in enumerate(connections):
            key = f"conn{i}[{c.aspsp_name}]"
            seen[key] = _stamp(c.last_synced_at)
            print(
                f"  {key} status={c.status} accounts={c.account_count} "
                f"valid_until={_stamp(c.valid_until)} last_synced_at={seen[key]}",
                flush=True,
            )
        return seen


    def main() -> int:
        started = dt.datetime.now(dt.timezone.utc)
        print(f"run_at {started.isoformat(timespec='seconds')}", flush=True)
        with OpenBankingClient(
            api_base_url=_read("obi_base_url"),
            api_key=_read("obi_api_key"),
            private_key_pkcs8=_read("obi_private_key"),
        ) as client:
            print("before:", flush=True)
            before = _report(client.get_connections())
            result = client.sync_all()
            print(
                f"sync_all accounts={result.accounts} new_transactions={result.new_transactions}",
                flush=True,
            )
            print("after:", flush=True)
            after = _report(client.get_connections())

        stalled = [key for key, stamp in after.items() if before.get(key) == stamp]
        for key in stalled:
            print(f"NOT REFRESHED {key} last_synced_at still {after[key]}", flush=True)
        if stalled:
            print(
                f"soft failure: {len(stalled)}/{len(after)} connection(s) did not advance",
                flush=True,
            )
            return 1
        print(f"ok: {len(after)} connection(s) advanced", flush=True)
        return 0


    if __name__ == "__main__":
        try:
            sys.exit(main())
        except Exception as exc:  # noqa: BLE001 - the journal is the only reporter
            print(f"FAILED {type(exc).__name__}: {str(exc)[:300]}", flush=True)
            sys.exit(1)
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
  syncStart = pkgs.writeShellApplication {
    name = "obi-mcp-sync";
    runtimeInputs = [
      pkgs.uv
      pkgs.git
      python
    ];
    text = ''
      : "''${CREDENTIALS_DIRECTORY:?}"
      # Same interpreter pin as obi-mcp-http (uv-managed CPython would hit the
      # NixOS musl stub-ld) and the same pinned upstream, so the SDK that syncs
      # is the SDK the sidecar reads with.
      export UV_PYTHON=${lib.getExe python}
      export UV_PYTHON_DOWNLOADS=never
      exec uvx --python "$UV_PYTHON" --from ${lib.escapeShellArg from} -- python ${sync}
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

  # Daily AIS refresh. Without it the feed only moves when a human opens the
  # app; every pull after the first is incremental and additive.
  systemd.services.obi-mcp-sync = {
    description = "open-banking.io AIS refresh (SDK sync_all, daily)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe syncStart;
      # A refused/partial refresh exits 1 and is listed in the journal. That is
      # a soft failure to read, not a crash loop: never restart on failure.
      Restart = "no";
      TimeoutStartSec = 300;
      DynamicUser = true;
      StateDirectory = "obi-mcp-sync";
      WorkingDirectory = "/var/lib/obi-mcp-sync";
      LoadCredential = [
        "obi_api_key:${config.sops.secrets.obi_api_key.path}"
        "obi_private_key:${config.sops.secrets.obi_private_key.path}"
        "obi_base_url:${config.sops.secrets.obi_base_url.path}"
      ];
      Environment = [
        "HOME=/var/lib/obi-mcp-sync"
        "UV_CACHE_DIR=/var/lib/obi-mcp-sync/uv"
        "UV_PYTHON_DOWNLOADS=never"
      ];
      MemoryMax = "512M";
      OOMScoreAdjust = 400;
      ProtectSystem = "strict";
      ExecPaths = [ "/var/lib/obi-mcp-sync" ];
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

  systemd.timers.obi-mcp-sync = {
    description = "Daily open-banking.io AIS refresh";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:15:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
      Unit = "obi-mcp-sync.service";
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
