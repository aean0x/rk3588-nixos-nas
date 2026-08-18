# Host leftovers after hermes-pnp owns serve + MCP URL.
# Composer starts gbrain-mcp-http when hermesPnP.gbrain.enable.
# This file: 1G RAM cap, native programs.git identity + PAT helper
# (store path, /nix/store bind-mounted into the gateway container),
# /etc/gitconfig bind-mounted into the container, config.yaml nits.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = config.services.hermes-agent;
  home = "${agent.stateDir}/home";           # /var/lib/hermes/home  (container: /home/hermes)
  hermesHome = "${agent.stateDir}/.hermes";

  # PAT credential helper as a store path. /nix/store is bind-mounted ro into
  # the gateway container, so the SAME path resolves on host and in-container.
  # No install step, no git config --global -- one path for both surfaces.
  gitCredentialHelper = pkgs.writeShellApplication {
    name = "git-credential-github-env";
    runtimeInputs = [ pkgs.gnugrep pkgs.coreutils ];
    checkPhase = "";
    text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ../scripts/git-credential-github-env);
  };
in
{
  # Machine-wide identity + credential helper (AGENTS.md aean0x rule).
  # Native -> /etc/gitconfig. The gateway git-hook runs in a container with
  # its own /etc, so /etc/gitconfig is bind-mounted in below (extraVolumes).
  # Override = edit the values here (single source of truth in this flake).
  # ISO keeps programs.git.enable = false.
  programs.git = {
    enable = true;
    config = {
      user = {
        name = "aean0x";
        email = "3682177+aean0x@users.noreply.github.com";
      };
      credential = {
        helper = "${gitCredentialHelper}/bin/git-credential-github-env";
        useHttpPath = true;
      };
    };
  };

  # The gateway container ships its own /etc (Ubuntu image), so the host's
  # native /etc/gitconfig would never reach the git-hook. Share it read-only.
  services.hermes-agent.container.extraVolumes = [
    "/etc/gitconfig:/etc/gitconfig:ro"
  ];

  systemd.services.gbrain-mcp-http.serviceConfig = {
    MemoryMax = "1G";
    OOMScoreAdjust = 400;
  };

  system.activationScripts.hermes-gbrain-site = lib.stringAfter [ "hermes-gbrain" ] ''
    if command -v git >/dev/null 2>&1; then
      # Drop stale per-user + local identity that would shadow /etc/gitconfig
      # (git precedence: local > global > system). One-time migration; the
      # native system config above is the going-forward source of truth.
      sudo -u hermes env HOME=${home} git config --global --unset-all user.name || true
      sudo -u hermes env HOME=${home} git config --global --unset-all user.email || true
      sudo -u hermes env HOME=${home} git config --global --unset-all safe.directory || true
      sudo -u hermes env HOME=${home} git config --global --unset-all credential.helper || true
      sudo -u hermes env HOME=${home} git config --global --unset-all credential.useHttpPath || true
      if [ -d ${hermesHome}/projects/.git ]; then
        sudo -u hermes env HOME=${home} git -C ${hermesHome}/projects config --local --unset-all user.name || true
        sudo -u hermes env HOME=${home} git -C ${hermesHome}/projects config --local --unset-all user.email || true
      fi
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

# Stale pre-agent.max_turns key; agent.max_turns is authoritative.
agent_block = data.get("agent")
if isinstance(agent_block, dict) and "max_turns" in agent_block and "max_turns" in data:
    del data["max_turns"]
    changed = True

# hermes doctor: missing key is reported as v0.
if data.get("_config_version") in (None, 0):
    data["_config_version"] = 33
    changed = True

if changed:
    path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
PY
      chown hermes:hermes "$cfg" 2>/dev/null || true
    fi
  '';
}
