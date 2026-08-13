# Hermes ↔ G-Brain: registry, shared HTTP MCP client, gbrain-mcp-http unit.
#
# PGLite is single-writer. One supervised `gbrain serve --http` owns PGLite;
# all clients use HTTP MCP URL (gateway + WebUI + CLI).
#
# Plugins (gbrain-retrieval-reflex, memory-flush, …): integrations/
# No exclusive consolidate/dream host wrappers. No static pointer JSON.
{
  lib,
  pkgs,
  hermes,
  ...
}:

let
  memoryDir = ./memory;
  registryFile = "${memoryDir}/registry.json";
  schemaFile = "${memoryDir}/export-schema.json";
  agentsManifest = "${memoryDir}/AGENTS.md";

  gbrainHttpPort = 3131;
  gbrainMcpUrl = "http://127.0.0.1:${toString gbrainHttpPort}/mcp";

  gbrainBin = "${hermes.home}/.bun/bin/gbrain";

  # Host-side long-lived serve (sole PGLite owner). Bun global under hermes HOME.
  gbrainHttpScript = pkgs.writeShellScript "gbrain-mcp-http" ''
    set -euo pipefail
    export HOME="${hermes.home}"
    export PATH="${hermes.hostPath}"
    if [ ! -x "${gbrainBin}" ] && ! command -v gbrain >/dev/null 2>&1; then
      echo "gbrain-mcp-http: gbrain not installed under ${hermes.home}/.bun/bin (bootstrap first)" >&2
      exit 1
    fi
    cd "$HOME"
    exec gbrain serve --http --port ${toString gbrainHttpPort} --bind 127.0.0.1
  '';
in
{
  services.hermes-agent = {
    # Shared HTTP MCP — no per-agent stdio spawn of gbrain.
    mcpServers.gbrain = {
      url = gbrainMcpUrl;
      connect_timeout = 120;
      timeout = 120;
    };

    environment = {
      HERMES_MEMORY_REGISTRY = hermes.memoryRegistry.container;
      GBRAIN_AUDIT_DIR = hermes.gbrainAudit.container;
    };
  };

  # Sole PGLite owner for multi-client Hermes (gateway + WebUI + CLI).
  systemd.services.gbrain-mcp-http = {
    description = "GBrain MCP HTTP (loopback; sole PGLite writer)";
    after = [
      "network-online.target"
      "hermes-agent-setup.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      # ZEROENTROPY_API_KEY and other keys for embeddings.
      EnvironmentFile = [ "-/run/hermes.env" ];
      Environment = [
        "HOME=${hermes.home}"
        "PATH=${hermes.hostPath}"
      ];
      WorkingDirectory = hermes.home;
      ExecStart = "${gbrainHttpScript}";
      Restart = "on-failure";
      RestartSec = 10;
      # Avoid tight crash loops when PGLite is locked/damaged.
      StartLimitIntervalSec = 120;
      StartLimitBurst = 5;
      TimeoutStartSec = "120";
      # Tertiary memory plane — prefer kill over AdGuard/HA if the box is desperate.
      MemoryMax = "1G";
      OOMScoreAdjust = 400;
    };
  };

  # Agents attach after HTTP serve is up (best-effort; they retry connect).
  systemd.services.hermes-agent = {
    after = [ "gbrain-mcp-http.service" ];
    wants = [ "gbrain-mcp-http.service" ];
  };
  # Safe even if webui module is disabled (empty merge).
  systemd.services.hermes-webui = {
    after = [ "gbrain-mcp-http.service" ];
    wants = [ "gbrain-mcp-http.service" ];
  };

  system.activationScripts.hermes-memory-manifest = lib.stringAfter [ "hermes-agent-setup" ] ''
    install -d -m 0755 -o hermes -g hermes ${hermes.bin}
    rm -f ${hermes.workspace}/gbrain-pointer-index.json

    # ── Always managed (memory contract / registry) ──
    install -d -m 0755 -o hermes -g hermes ${hermes.stateDir}/memory
    install -m 0644 ${registryFile} ${hermes.memoryRegistry.host}
    install -m 0644 ${schemaFile} /var/lib/hermes/memory/export-schema.json
    install -m 0644 ${agentsManifest} /var/lib/hermes/memory/AGENTS.md

    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/inbox
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/snapshots
    chown -R hermes:hermes /var/lib/hermes/.hermes/memories/export

    # Purge the old Nix-injected manifesto. $HERMES_HOME/AGENTS.md is not
    # workspace context (cwd is /data/workspace); leave the slot to Hermes/GBrain.
    rm -f ${hermes.hermesHome}/AGENTS.md

    # GBrain ~/brain (and any hermes-user git to github.com) uses GITHUB_PAT.
    install -d -m 0755 -o hermes -g hermes ${hermes.hermesHome}/scripts
    install -m 0755 -o hermes -g hermes ${./scripts/git-credential-github-env} \
      ${hermes.hermesHome}/scripts/git-credential-github-env
    if command -v git >/dev/null 2>&1; then
      sudo -u hermes git config --global credential.helper \
        ${hermes.hermesHome}/scripts/git-credential-github-env || true
      sudo -u hermes git config --global credential.useHttpPath true || true
    fi

    if [ ! -f /var/lib/hermes/.hermes/memories/MEMORY.md ]; then
      {
        echo '# MEMORY.md — working / short-horizon only'
        echo
        echo 'Durable knowledge → GBrain MCP put_page (ops/gbrain-protocol).'
      } > /var/lib/hermes/.hermes/memories/MEMORY.md
      chown hermes:hermes /var/lib/hermes/.hermes/memories/MEMORY.md
      chmod 0640 /var/lib/hermes/.hermes/memories/MEMORY.md
    fi

    install -d -m 2770 -o hermes -g hermes ${hermes.workspace}

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain/audit
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/brain

    if [ ! -e /home/hermes ]; then
      ln -sfn /var/lib/hermes/home /home/hermes
    elif [ ! -L /home/hermes ] && [ ! -d /home/hermes ]; then
      ln -sfn /var/lib/hermes/home /home/hermes
    fi

    cfg=/var/lib/hermes/.hermes/config.yaml
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
# Shared HTTP MCP (sole gbrain process). Drop stdio command/args/env.
# Bearer: gbrain HTTP requires auth. Prefer token file minted once by operator
# (`gbrain auth create hermes-agents` → ~/.gbrain/hermes-mcp.token); preserve
# existing headers if file missing so deploy does not wipe live auth.
desired_mcp = {
    "url": "${gbrainMcpUrl}",
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
    # Optional: GBRAIN_REMOTE_TOKEN=... in hermes .env (Hermes-owned)
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
# Literal Bearer only. Reject unexpanded dollar-brace placeholders in the token.
_ph = "$" + "{"
if token and _ph not in token:
    desired_mcp["headers"] = {"Authorization": "Bearer " + token}
elif isinstance(cur.get("headers"), dict) and cur.get("headers"):
    auth = str(cur["headers"].get("Authorization") or cur["headers"].get("authorization") or "")
    if auth.startswith("Bearer ") and _ph not in auth:
        desired_mcp["headers"] = {"Authorization": auth}
# Normalize: never keep stdio fields on gbrain entry
if mcp.get("gbrain") != desired_mcp:
    mcp["gbrain"] = desired_mcp
    changed = True

# plugins.enabled: integrations/default.nix (single-root $HERMES_HOME/plugins)

if changed:
    path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
PY
      chown hermes:hermes "$cfg" 2>/dev/null || true
    fi
  '';
}
