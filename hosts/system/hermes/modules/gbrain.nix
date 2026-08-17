# Host leftovers after hermes-pnp owns serve + MCP URL.
# Composer starts gbrain-mcp-http when hermesPnP.gbrain.enable.
# This file: 8GiB RAM cap, git-credential helper, config.yaml Bearer rewrite.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = config.services.hermes-agent;
  home = "${agent.stateDir}/home";
  hermesHome = "${agent.stateDir}/.hermes";
  gitCredential = ../scripts/git-credential-github-env;
in
{
  systemd.services.gbrain-mcp-http.serviceConfig = {
    MemoryMax = "1G";
    OOMScoreAdjust = 400;
  };

  system.activationScripts.hermes-gbrain-site = lib.stringAfter [ "hermes-gbrain" ] ''
    install -d -m 0755 -o hermes -g hermes ${hermesHome}/scripts
    install -d -m 0755 -o hermes -g hermes ${home}/.local/bin
    install -m 0755 -o hermes -g hermes ${gitCredential} \
      ${hermesHome}/scripts/git-credential-github-env
    install -m 0755 -o hermes -g hermes ${gitCredential} \
      ${home}/.local/bin/git-credential-github-env
    if command -v git >/dev/null 2>&1; then
      sudo -u hermes env HOME=${home} git config --global credential.helper \
        /home/hermes/.local/bin/git-credential-github-env || true
      sudo -u hermes env HOME=${home} git config --global credential.useHttpPath true || true
    fi

    install -d -m 2770 -o hermes -g hermes ${agent.stateDir}/workspace

    cfg=${hermesHome}/config.yaml
    if [ -f "$cfg" ]; then
      ${pkgs.python3}/bin/python3 - "$cfg" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit(0)
path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text()) or {}
changed = False

mcp = data.setdefault("mcp_servers", {})
desired_mcp = {
    "url": "http://127.0.0.1:3131/mcp",
    "connect_timeout": 120,
    "timeout": 120,
    "enabled": True,
}
token = ""
for tp in (
    Path("/var/lib/hermes/home/.gbrain/hermes-mcp.token"),
    Path("/home/hermes/.gbrain/hermes-mcp.token"),
):
    try:
        if tp.is_file():
            token = tp.read_text(encoding="utf-8").strip()
            if token:
                break
    except OSError:
        pass
if not token:
    for ep in (
        Path("/var/lib/hermes/.hermes/.env"),
        Path("/home/hermes/.hermes/.env"),
    ):
        try:
            if not ep.is_file():
                continue
            for line in ep.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("GBRAIN_REMOTE_TOKEN="):
                    token = line.split("=", 1)[1].strip().strip('"').strip("'")
                    break
        except OSError:
            pass
        if token:
            break
cur = mcp.get("gbrain") or {}
_ph = "$" + "{"
if token and _ph not in token:
    desired_mcp["headers"] = {"Authorization": "Bearer " + token}
elif isinstance(cur.get("headers"), dict) and cur.get("headers"):
    auth = str(cur["headers"].get("Authorization") or cur["headers"].get("authorization") or "")
    if auth.startswith("Bearer ") and _ph not in auth:
        desired_mcp["headers"] = {"Authorization": auth}
if mcp.get("gbrain") != desired_mcp:
    mcp["gbrain"] = desired_mcp
    changed = True

if changed:
    path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
PY
      chown hermes:hermes "$cfg" 2>/dev/null || true
    fi
  '';
}
