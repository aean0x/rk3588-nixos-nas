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

  # Host wrappers: pause MCP, chown, docker exec inners with tool env.
  consolidateScript = pkgs.writeShellScriptBin "hermes-gbrain-consolidate" ''
    set -euo pipefail
    LOG_TAG="hermes-gbrain-consolidate"
    CONTAINER="''${HERMES_CONTAINER:-hermes-agent}"
    INNER="''${HERMES_GBRAIN_CONSOLIDATE_INNER:-/data/bin/hermes-gbrain-consolidate-inner}"
    log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",\"msg\":$1}"; }
    if ! ${pkgs.docker}/bin/docker inspect "$CONTAINER" >/dev/null 2>&1; then
      log '"error":"container not found"'
      exit 1
    fi
    if ! ${pkgs.docker}/bin/docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
      log '"error":"container not running"'
      exit 1
    fi
    ${pkgs.docker}/bin/docker exec "$CONTAINER" pkill -f 'gbrain serve' 2>/dev/null || true
    sleep 2
    ${pkgs.docker}/bin/docker exec "$CONTAINER" chown -R hermes:hermes /home/hermes/.gbrain /home/hermes/brain 2>/dev/null || true
    ${pkgs.docker}/bin/docker exec -u hermes \
      -e HERMES_JQ=${jqBin} \
      -e HERMES_PYTHON3=${python3Bin} \
      -e HERMES_NIX_BIN=${nixBinPath} \
      -e HERMES_MEMORY_REGISTRY=/data/memory/registry.json \
      "$CONTAINER" /usr/bin/bash "$INNER"
    log '"status":"complete"'
  '';

  embedScript = pkgs.writeShellScriptBin "hermes-gbrain-embed" ''
    set -euo pipefail
    LOG_TAG="hermes-gbrain-embed"
    CONTAINER="''${HERMES_CONTAINER:-hermes-agent}"
    INNER="''${HERMES_GBRAIN_EMBED_INNER:-/data/bin/hermes-gbrain-embed-inner}"
    log() { echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"component\":\"$LOG_TAG\",\"msg\":$1}"; }
    if ! ${pkgs.docker}/bin/docker inspect "$CONTAINER" >/dev/null 2>&1; then
      log '"error":"container not found"'
      exit 1
    fi
    if ! ${pkgs.docker}/bin/docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
      log '"error":"container not running"'
      exit 1
    fi
    ${pkgs.docker}/bin/docker exec "$CONTAINER" pkill -f 'gbrain serve' 2>/dev/null || true
    sleep 2
    ${pkgs.docker}/bin/docker exec "$CONTAINER" chown -R hermes:hermes /home/hermes/.gbrain /home/hermes/brain 2>/dev/null || true
    ${pkgs.docker}/bin/docker exec -u hermes \
      -e HERMES_JQ=${jqBin} \
      -e HERMES_NIX_BIN=${nixBinPath} \
      -e HERMES_MEMORY_REGISTRY=/data/memory/registry.json \
      "$CONTAINER" /usr/bin/bash "$INNER"
    log '"status":"complete"'
  '';

  containerEnv = ''
    export PATH="/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:${nixBinPath}:/usr/bin:/bin"
    export HERMES_JQ=${jqBin}
    export HERMES_PYTHON3=${python3Bin}
    export HERMES_MEMORY_REGISTRY=/data/memory/registry.json
    if [ -f "$HERMES_MEMORY_REGISTRY" ]; then
      CANON=/data/memory/AGENTS.md
      LIVE=/data/.hermes/AGENTS.md
      if [ -f "$CANON" ] && [ -f "$LIVE" ] && ! cmp -s "$CANON" "$LIVE"; then
        echo "{\"error\":\"agents_md_drift\",\"canonical\":\"$CANON\",\"live\":\"$LIVE\"}" >&2
        exit 5
      fi
      echo "{\"event\":\"gbrain_startup\",\"registry\":\"$HERMES_MEMORY_REGISTRY\",\"memory_md\":\"$(${jqBin} -r .hermes_memory.builtin_profile.memory_md.container "$HERMES_MEMORY_REGISTRY")\",\"pglite\":\"$(${jqBin} -r .gbrain_memory.pglite_data.container "$HERMES_MEMORY_REGISTRY")\"}"
    fi
    if [ -f /data/.hermes/.env ]; then
      for _gk in ZEROENTROPY_API_KEY OPENAI_API_KEY; do
        _gl=$(grep -m1 "^''${_gk}=" /data/.hermes/.env 2>/dev/null || true)
        [ -n "$_gl" ] && export "$_gl"
      done
    fi
  '';

  pauseGbrainMcp = ''
    ${pkgs.docker}/bin/docker exec hermes-agent pkill -f 'gbrain serve' 2>/dev/null || true
    sleep 2
    ${pkgs.docker}/bin/docker exec hermes-agent chown -R hermes:hermes /home/hermes/.gbrain /home/hermes/brain 2>/dev/null || true
  '';

  dreamWrapper = pkgs.writeShellScript "gbrain-dream-host" ''
    ${pauseGbrainMcp}
    ${pkgs.docker}/bin/docker exec -u hermes hermes-agent bash -lc '${containerEnv}; mkdir -p /data/.hermes/memories/export; flock -n /data/.hermes/memories/export/.consolidation.lock -c "gbrain dream" || { echo "{\"skipped\":true,\"reason\":\"consolidation_lock_held\"}"; exit 0; }'
  '';

  gbrainMcpCleanup = pkgs.writeShellScript "hermes-gbrain-mcp-cleanup" ''
    if ${pkgs.docker}/bin/docker inspect hermes-agent >/dev/null 2>&1; then
      ${pkgs.docker}/bin/docker exec hermes-agent pkill -f 'gbrain serve' 2>/dev/null || true
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

    # Non-secret env merged into $HERMES_HOME/.env (visible in store — no secrets).
    environment = {
      HERMES_MEMORY_REGISTRY = "/data/memory/registry.json";
      GBRAIN_AUDIT_DIR = "/home/hermes/.gbrain/audit";
      # bun globals (gbrain) + common bins for agent children / MCP.
      PATH = "/home/hermes/.npm-global/bin:/home/hermes/.bun/bin:/data/toolbox/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    };

    extraPackages = [
      pkgs.jq
      pkgs.python3
      pkgs.git
      pkgs.bun
    ];
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

  # Avoid orphaned gbrain MCP children after restarts (PGLite lock fights with timers).
  systemd.services.hermes-agent.preStart = lib.mkAfter ''
    ${gbrainMcpCleanup}
  '';
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
        echo '# MEMORY.md'
        echo
        echo 'Long-term facts: use Hermes memory tools and G-Brain (see AGENTS.md memory manifest).'
        echo 'Registry: `/var/lib/hermes/memory/registry.json`.'
      } > /var/lib/hermes/.hermes/memories/MEMORY.md
      chown hermes:hermes /var/lib/hermes/.hermes/memories/MEMORY.md
      chmod 0640 /var/lib/hermes/.hermes/memories/MEMORY.md
    fi
    PROBE_MARKER="integration-probe:"
    if ! grep -qF "$PROBE_MARKER" /var/lib/hermes/.hermes/memories/MEMORY.md 2>/dev/null; then
      printf '\n- %s rocknas gbrain inbox import validation fact (deploy-seeded).\n' "$PROBE_MARKER" >> /var/lib/hermes/.hermes/memories/MEMORY.md
      chown hermes:hermes /var/lib/hermes/.hermes/memories/MEMORY.md
    fi

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    install -m 0755 ${consolidateInner} /var/lib/hermes/bin/hermes-gbrain-consolidate-inner
    install -m 0755 ${embedInner} /var/lib/hermes/bin/hermes-gbrain-embed-inner

    # Persist dirs for bun globals + brain git (gbrain install lives here).
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.gbrain/audit
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/brain
  '';
}
