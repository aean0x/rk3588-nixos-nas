# Hermes ↔ G-Brain memory linchpins: registry, manifest, consolidation timers.
# North star: ~/dev/hetzner-nixos modules/gbrain-integration.nix (+ hermes/memory/*).
# Organized under hosts/system/hermes/ for this NAS layout.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  memoryDir = ./memory;
  registryFile = "${memoryDir}/registry.json";
  schemaFile = "${memoryDir}/export-schema.json";
  agentsManifest = "${memoryDir}/AGENTS.md";

  jqBin = "${pkgs.jq}/bin/jq";
  python3Bin = "${pkgs.python3}/bin/python3";
  nixBinPath = lib.makeBinPath [
    pkgs.jq
    pkgs.python3
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gawk
    pkgs.util-linux # flock
  ];

  # Plain text inners (no Nix shebang); tools resolved via HERMES_JQ / PATH.
  consolidateInner = pkgs.writeText "hermes-gbrain-consolidate-inner" (
    builtins.readFile ./scripts/hermes-gbrain-consolidate-inner.sh
  );

  embedInner = pkgs.writeText "hermes-gbrain-embed-inner" (
    builtins.readFile ./scripts/hermes-gbrain-embed-inner.sh
  );

  exclusiveCli = pkgs.writeText "gbrain-exclusive-cli" (
    builtins.readFile ./scripts/gbrain-exclusive-cli.sh
  );

  # After exclusive CLI, MCP serve may be gone (watchdog does not always revive).
  # Soft-restart the gateway only when bun gbrain serve is missing.
  ensureGbrainMcp = ''
    CONTAINER="''${HERMES_CONTAINER:-hermes-agent}"
    if ! ${pkgs.docker}/bin/docker exec "$CONTAINER" sh -c 'ps -o args= -C bun 2>/dev/null | grep -q gbrain' 2>/dev/null; then
      echo "{\"event\":\"gbrain_mcp_recover\",\"action\":\"restart_hermes-agent\"}"
      ${pkgs.systemd}/bin/systemctl restart hermes-agent.service || true
      # give MCP serve a moment to come back
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ${pkgs.docker}/bin/docker exec "$CONTAINER" sh -c 'ps -o args= -C bun 2>/dev/null | grep -q gbrain' 2>/dev/null; then
          break
        fi
        sleep 1
      done
    fi
  '';

  # Host wrappers: exclusive PGLite (freeze MCP watchdog → CLI → resume), chown, docker exec.
  consolidateScript = pkgs.writeShellScriptBin "hermes-gbrain-consolidate" ''
    set -euo pipefail
    LOG_TAG="hermes-gbrain-consolidate"
    CONTAINER="''${HERMES_CONTAINER:-hermes-agent}"
    INNER="''${HERMES_GBRAIN_CONSOLIDATE_INNER:-/data/bin/hermes-gbrain-consolidate-inner}"
    EXCL="''${HERMES_GBRAIN_EXCLUSIVE_CLI:-/data/bin/gbrain-exclusive-cli}"
    log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",\"msg\":$1}"; }
    if ! ${pkgs.docker}/bin/docker inspect "$CONTAINER" >/dev/null 2>&1; then
      log '"error":"container not found"'
      exit 1
    fi
    if ! ${pkgs.docker}/bin/docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
      log '"error":"container not running"'
      exit 1
    fi
    ${pkgs.docker}/bin/docker exec "$CONTAINER" chown -R hermes:hermes /home/hermes/.gbrain /home/hermes/brain 2>/dev/null || true
    ${pkgs.docker}/bin/docker exec \
      -e HERMES_JQ=${jqBin} \
      -e HERMES_PYTHON3=${python3Bin} \
      -e HERMES_NIX_BIN=${nixBinPath} \
      -e HERMES_MEMORY_REGISTRY=/data/memory/registry.json \
      "$CONTAINER" /usr/bin/bash "$EXCL" -- /usr/bin/bash "$INNER"
    ${ensureGbrainMcp}
    log '"status":"complete"'
  '';

  embedScript = pkgs.writeShellScriptBin "hermes-gbrain-embed" ''
    set -euo pipefail
    LOG_TAG="hermes-gbrain-embed"
    CONTAINER="''${HERMES_CONTAINER:-hermes-agent}"
    INNER="''${HERMES_GBRAIN_EMBED_INNER:-/data/bin/hermes-gbrain-embed-inner}"
    EXCL="''${HERMES_GBRAIN_EXCLUSIVE_CLI:-/data/bin/gbrain-exclusive-cli}"
    log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",\"msg\":$1}"; }
    if ! ${pkgs.docker}/bin/docker inspect "$CONTAINER" >/dev/null 2>&1; then
      log '"error":"container not found"'
      exit 1
    fi
    if ! ${pkgs.docker}/bin/docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
      log '"error":"container not running"'
      exit 1
    fi
    ${pkgs.docker}/bin/docker exec "$CONTAINER" chown -R hermes:hermes /home/hermes/.gbrain /home/hermes/brain 2>/dev/null || true
    ${pkgs.docker}/bin/docker exec \
      -e HERMES_JQ=${jqBin} \
      -e HERMES_NIX_BIN=${nixBinPath} \
      -e HERMES_MEMORY_REGISTRY=/data/memory/registry.json \
      -e FORCE_GBRAIN_EMBED="''${FORCE_GBRAIN_EMBED:-}" \
      "$CONTAINER" /usr/bin/bash "$EXCL" -- /usr/bin/bash "$INNER"
    ${ensureGbrainMcp}
    log '"status":"complete"'
  '';

  dreamWrapper = pkgs.writeShellScript "gbrain-dream-host" ''
    set -euo pipefail
    CONTAINER="''${HERMES_CONTAINER:-hermes-agent}"
    EXCL="''${HERMES_GBRAIN_EXCLUSIVE_CLI:-/data/bin/gbrain-exclusive-cli}"
    ${pkgs.docker}/bin/docker exec hermes-agent chown -R hermes:hermes /home/hermes/.gbrain /home/hermes/brain 2>/dev/null || true
    ${pkgs.docker}/bin/docker exec \
      -e HERMES_JQ=${jqBin} \
      -e HERMES_PYTHON3=${python3Bin} \
      -e HERMES_NIX_BIN=${nixBinPath} \
      -e HERMES_MEMORY_REGISTRY=/data/memory/registry.json \
      "$CONTAINER" /usr/bin/bash "$EXCL" -- \
      /usr/bin/bash -lc 'mkdir -p /data/.hermes/memories/export; flock -n /data/.hermes/memories/export/.consolidation.lock -c "gbrain dream" || { echo "{\"skipped\":true,\"reason\":\"consolidation_lock_held\"}"; exit 0; }'
    ${ensureGbrainMcp}
  '';

  # Only on hermes-agent stop — do not fight live MCP during normal runtime.
  gbrainMcpCleanup = pkgs.writeShellScript "hermes-gbrain-mcp-cleanup" ''
    if ${pkgs.docker}/bin/docker inspect hermes-agent >/dev/null 2>&1; then
      ${pkgs.docker}/bin/docker exec hermes-agent bash -c '
        for proc in /proc/[0-9]*; do
          [ -r "$proc/cmdline" ] || continue
          cmd=$(tr "\0" " " <"$proc/cmdline" 2>/dev/null || true)
          case "$cmd" in
            *mcp_stdio_watchdog*|*"/gbrain serve"*|*"gbrain serve"*|*bun*"/.bun/bin/gbrain"*)
              kill -TERM "''${proc#/proc/}" 2>/dev/null || true
              ;;
          esac
        done
      ' 2>/dev/null || true
      sleep 1
    fi
  '';
in
{
  # MCP: gbrain serve as stdio server (tools appear as mcp_gbrain_*).
  services.hermes-agent = {
    mcpServers.gbrain = {
      command = "gbrain";
      args = [ "serve" ];
      connect_timeout = 120;
      timeout = 120;
      env = {
        HOME = "/home/hermes";
      };
    };

    # Non-secret env (PATH / HERMES_PY live in toolbox.nix so one source of truth).
    environment = {
      HERMES_MEMORY_REGISTRY = "/data/memory/registry.json";
      GBRAIN_AUDIT_DIR = "/home/hermes/.gbrain/audit";
    };
  };

  systemd.services.hermes-gbrain-consolidate = {
    description = "Hermes memory snapshot + G-Brain inbox import";
    after = [
      "hermes-agent.service"
      "docker.service"
    ];
    requires = [ "hermes-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${consolidateScript}/bin/hermes-gbrain-consolidate";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.timers.hermes-gbrain-consolidate = {
    description = "Daily Hermes → G-Brain consolidation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "45min";
      Persistent = true;
    };
  };

  systemd.services.gbrain-dream = {
    description = "G-Brain overnight maintenance (dream)";
    after = [ "hermes-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = dreamWrapper;
    };
  };

  systemd.timers.gbrain-dream = {
    description = "G-Brain dream timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:30";
      Persistent = true;
    };
  };

  systemd.services.gbrain-embed = {
    description = "G-Brain delta embedding refresh";
    after = [ "hermes-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${embedScript}/bin/hermes-gbrain-embed";
    };
  };

  systemd.timers.gbrain-embed = {
    description = "G-Brain embed timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 05:00";
      Persistent = true;
    };
  };

  environment.systemPackages = [
    consolidateScript
    embedScript
  ];

  # Orphan cleanup only when the gateway is going down (not preStart — MCP owns serve while up).
  systemd.services.hermes-agent.postStop = lib.mkAfter ''
    ${gbrainMcpCleanup}
  '';

  # Install memory registry + AGENTS manifest + export plane + inners.
  # Does NOT install SOUL.md (identity left undeclared / agent-owned).
  system.activationScripts.hermes-memory-manifest = lib.stringAfter [ "hermes-agent-setup" ] ''
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/memory
    install -m 0644 ${registryFile} /var/lib/hermes/memory/registry.json
    install -m 0644 ${schemaFile} /var/lib/hermes/memory/export-schema.json
    install -m 0644 ${agentsManifest} /var/lib/hermes/memory/AGENTS.md

    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/inbox
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/.hermes/memories/export/snapshots
    chown -R hermes:hermes /var/lib/hermes/.hermes/memories/export

    # Canonical memory contract → live HERMES_HOME AGENTS.md (not SOUL/identity).
    install -m 0640 -o hermes -g hermes ${agentsManifest} /var/lib/hermes/.hermes/AGENTS.md

    if [ ! -f /var/lib/hermes/.hermes/memories/MEMORY.md ]; then
      {
        echo '# MEMORY.md — working / short-horizon only'
        echo
        echo 'Durable knowledge belongs in **GBrain** (MCP put_page / query), not here.'
        echo 'See AGENTS.md §7 and workspace/GBRAIN.md.'
        echo 'Registry: `/data/memory/registry.json`.'
      } > /var/lib/hermes/.hermes/memories/MEMORY.md
      chown hermes:hermes /var/lib/hermes/.hermes/memories/MEMORY.md
      chmod 0640 /var/lib/hermes/.hermes/memories/MEMORY.md
    fi

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    install -m 0755 ${consolidateInner} /var/lib/hermes/bin/hermes-gbrain-consolidate-inner
    install -m 0755 ${embedInner} /var/lib/hermes/bin/hermes-gbrain-embed-inner
    install -m 0755 ${exclusiveCli} /var/lib/hermes/bin/gbrain-exclusive-cli

    # Agent-facing protocol (workingDirectory bind → /data/workspace).
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/workspace
    install -m 0640 -o hermes -g hermes ${./workspace/GBRAIN.md} /var/lib/hermes/workspace/GBRAIN.md

    # Persist dirs for bun globals + brain git (gbrain install lives here).
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain/audit
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/brain
  '';
}
