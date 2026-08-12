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
  ...
}:

let
  memoryDir = ./memory;
  registryFile = "${memoryDir}/registry.json";
  schemaFile = "${memoryDir}/export-schema.json";
  agentsManifest = "${memoryDir}/AGENTS.md";

  gbrainHttpPort = 3131;
  gbrainMcpUrl = "http://127.0.0.1:${toString gbrainHttpPort}/mcp";

  hermesHome = "/var/lib/hermes/home";
  gbrainBin = "${hermesHome}/.bun/bin/gbrain";

  # Host-side long-lived serve (sole PGLite owner). Bun global under hermes HOME.
  gbrainHttpScript = pkgs.writeShellScript "gbrain-mcp-http" ''
    set -euo pipefail
    export HOME="${hermesHome}"
    export PATH="${hermesHome}/.bun/bin:${hermesHome}/.npm-global/bin:/var/lib/hermes/toolbox/bin:/run/current-system/sw/bin:/usr/bin:/bin"
    if [ ! -x "${gbrainBin}" ] && ! command -v gbrain >/dev/null 2>&1; then
      echo "gbrain-mcp-http: gbrain not installed under ${hermesHome}/.bun/bin (bootstrap first)" >&2
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
      HERMES_MEMORY_REGISTRY = "/data/memory/registry.json";
      GBRAIN_AUDIT_DIR = "/home/hermes/.gbrain/audit";
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
        "HOME=${hermesHome}"
        "PATH=${hermesHome}/.bun/bin:${hermesHome}/.npm-global/bin:/var/lib/hermes/toolbox/bin:/run/current-system/sw/bin"
      ];
      WorkingDirectory = hermesHome;
      ExecStart = "${gbrainHttpScript}";
      Restart = "on-failure";
      RestartSec = 10;
      # Avoid tight crash loops when PGLite is locked/damaged.
      StartLimitIntervalSec = 120;
      StartLimitBurst = 5;
      TimeoutStartSec = "120";
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

  # Purge former exclusive-CLI surface (one generation of explicit disable is
  # enough if units still linger; units no longer defined elsewhere).
  systemd.services.hermes-gbrain-consolidate.enable = lib.mkForce false;
  systemd.timers.hermes-gbrain-consolidate.enable = lib.mkForce false;
  systemd.services.gbrain-dream.enable = lib.mkForce false;
  systemd.timers.gbrain-dream.enable = lib.mkForce false;
  systemd.services.gbrain-embed.enable = lib.mkForce false;
  systemd.timers.gbrain-embed.enable = lib.mkForce false;
  systemd.services.gbrain-nightly.enable = lib.mkForce false;
  systemd.timers.gbrain-nightly.enable = lib.mkForce false;

  system.activationScripts.hermes-memory-manifest = lib.stringAfter [ "hermes-agent-setup" ] ''
    # seed_if_missing DEST SRC MODE — Hermes owns content after first install.
    seed_if_missing() {
      dest="$1"; src="$2"; mode="$3"
      if [ ! -e "$dest" ]; then
        install -D -m "$mode" -o hermes -g hermes "$src" "$dest"
        echo "hermes-seed: created $dest"
      fi
    }

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    # Purge exclusive CLI + retired stdio serve wrapper (HTTP unit owns serve).
    rm -f /var/lib/hermes/bin/gbrain-mcp-serve \
      /var/lib/hermes/bin/gbrain-exclusive-cli \
      /var/lib/hermes/bin/hermes-gbrain-consolidate-inner \
      /var/lib/hermes/bin/hermes-gbrain-embed-inner \
      /var/lib/hermes/bin/hermes-gbrain-consolidate \
      /var/lib/hermes/bin/hermes-gbrain-dream \
      /var/lib/hermes/bin/hermes-gbrain-embed \
      /var/lib/hermes/bin/hermes-gbrain-nightly \
      /var/lib/hermes/bin/hermes-gbrain-exclusive
    rm -f /var/lib/hermes/workspace/gbrain-pointer-index.json

    # ── Always managed (memory contract / registry) ──
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/memory
    install -m 0644 ${registryFile} /var/lib/hermes/memory/registry.json
    install -m 0644 ${schemaFile} /var/lib/hermes/memory/export-schema.json
    install -m 0644 ${agentsManifest} /var/lib/hermes/memory/AGENTS.md

    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/inbox
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/snapshots
    chown -R hermes:hermes /var/lib/hermes/.hermes/memories/export

    install -m 0640 -o hermes -g hermes ${agentsManifest} /var/lib/hermes/.hermes/AGENTS.md

    if [ ! -f /var/lib/hermes/.hermes/memories/MEMORY.md ]; then
      {
        echo '# MEMORY.md — working / short-horizon only'
        echo
        echo 'Durable knowledge → GBrain MCP put_page (ops/gbrain-protocol).'
      } > /var/lib/hermes/.hermes/memories/MEMORY.md
      chown hermes:hermes /var/lib/hermes/.hermes/memories/MEMORY.md
      chmod 0640 /var/lib/hermes/.hermes/memories/MEMORY.md
    fi

    # Workspace is Hermes content only (no host GBRAIN.md / HERMES-WEBUI.md).
    # Operator refs: hosts/system/hermes/reference/{GBRAIN,HERMES-WEBUI}.md
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/workspace
    rm -f /var/lib/hermes/workspace/GBRAIN.md \
      /var/lib/hermes/workspace/HERMES-WEBUI.md \
      /var/lib/hermes/workspace/OPEN-WEBUI.md

    # Plugins: hosts/system/hermes/integrations (install + plugins.enabled).

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/.hermes/scripts
    install -m 0755 -o hermes -g hermes ${./scripts/projects_auto_commit.py} \
      /var/lib/hermes/.hermes/scripts/projects_auto_commit.py
    install -m 0755 -o hermes -g hermes ${./scripts/git-credential-github-env} \
      /var/lib/hermes/.hermes/scripts/git-credential-github-env
    if command -v git >/dev/null 2>&1; then
      sudo -u hermes git config --global credential.helper \
        /var/lib/hermes/.hermes/scripts/git-credential-github-env || true
      sudo -u hermes git config --global credential.useHttpPath true || true
    fi

    # Skills: retrieval + HTTP auth wiring (infra-owned policy text).
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/skills/retrieval-reflex
    install -m 0644 -o hermes -g hermes ${./skills/retrieval-reflex/SKILL.md} \
      /var/lib/hermes/skills/retrieval-reflex/SKILL.md
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/skills/gbrain-http-auth
    install -m 0644 -o hermes -g hermes ${./skills/gbrain-http-auth/SKILL.md} \
      /var/lib/hermes/skills/gbrain-http-auth/SKILL.md

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
