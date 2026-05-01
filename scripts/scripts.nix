# System management scripts
# Commands are discoverable via `help` and remotely via `deploy`
{
  config,
  pkgs,
  settings,
  ...
}:

let
  flakeRef = "github:${settings.repoUrl}#${settings.hostName}";
  logFile = "$HOME/.rebuild-log";

  containerNames = builtins.attrNames config.virtualisation.oci-containers.containers;

  mkContainerExec =
    name:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      if [[ $# -eq 0 ]]; then
        exec sudo docker exec -it ${name} /bin/sh
      else
        exec sudo docker exec -it ${name} "$@"
      fi
    '';

  containerScripts = map mkContainerExec containerNames;
in
{
  environment.systemPackages =
    with pkgs;
    containerScripts
    ++ [
      # Apply configuration immediately (fetch latest config)
      (writeShellScriptBin "switch" ''
        set -euo pipefail
        echo "=== Switch started at $(date) ===" | tee "${logFile}"
        echo "Rebuilding from ${flakeRef}..." | tee -a "${logFile}"
        sudo nixos-rebuild switch --flake "${flakeRef}" "$@" 2>&1 | tee -a "${logFile}"
        echo "Switch complete at $(date)" | tee -a "${logFile}"
      '')

      # Apply with updated nixpkgs/inputs (fetch latest config + update flake inputs)
      (writeShellScriptBin "upgrade" ''
        set -euo pipefail
        echo "=== Upgrade started at $(date) ===" | tee "${logFile}"
        echo "Rebuilding from ${flakeRef} with --upgrade (updates nixpkgs, etc.)..." | tee -a "${logFile}"
        sudo nixos-rebuild switch --flake "${flakeRef}" --upgrade "$@" 2>&1 | tee -a "${logFile}"
        echo "Refreshing container images..." | tee -a "${logFile}"
        sudo systemctl start refresh-containers.service 2>&1 | tee -a "${logFile}"
        echo "Upgrade complete at $(date)" | tee -a "${logFile}"
      '')

      # Build and apply on next reboot
      (writeShellScriptBin "boot" ''
        set -euo pipefail
        echo "=== Boot build started at $(date) ===" | tee "${logFile}"
        echo "Rebuilding from ${flakeRef}..." | tee -a "${logFile}"
        sudo nixos-rebuild boot --flake "${flakeRef}" "$@" 2>&1 | tee -a "${logFile}"
        echo "Boot build complete at $(date). Reboot to apply." | tee -a "${logFile}"
      '')

      # Try configuration temporarily (reverts on reboot)
      (writeShellScriptBin "try" ''
        set -euo pipefail
        echo "=== Try (test) started at $(date) ===" | tee "${logFile}"
        echo "Rebuilding from ${flakeRef}..." | tee -a "${logFile}"
        sudo nixos-rebuild test --flake "${flakeRef}" "$@" 2>&1 | tee -a "${logFile}"
        echo "Try complete at $(date) - will revert on reboot" | tee -a "${logFile}"
      '')

      # View last build log
      (writeShellScriptBin "build-log" ''
        if [[ -f "${logFile}" ]]; then
          cat "${logFile}"
        else
          echo "No build log found at ${logFile}"
        fi
      '')

      # Garbage collect and optimize store
      (writeShellScriptBin "cleanup" ''
        set -euo pipefail
        echo "Collecting garbage..."
        sudo nix-collect-garbage -d | grep freed || true
        echo "Optimizing store..."
        sudo nix-store --optimise
        echo "Cleanup complete."
      '')

      # Rollback to previous generation
      (writeShellScriptBin "rollback" ''
        set -euo pipefail
        echo "=== Rollback started at $(date) ===" | tee "${logFile}"
        sudo nixos-rebuild switch --rollback 2>&1 | tee -a "${logFile}"
        echo "Rollback complete at $(date)" | tee -a "${logFile}"
      '')

      # Show system info and status
      (writeShellScriptBin "system-info" ''
        echo "=== NixOS System Info ==="
        echo "Hostname: $(hostname)"
        echo "Flake: ${flakeRef}"
        echo ""
        echo "=== Current Generation ==="
        sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -5
        echo ""
        echo "=== Memory & Swap ==="
        free -h
        echo ""
        if [[ -f /sys/block/zram0/comp_algorithm ]]; then
          echo "zram: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]')"
        fi
        echo ""
        echo "=== Disk Usage ==="
        df -h / /nix 2>/dev/null || df -h /
        echo ""
        echo "=== Store Size ==="
        du -sh /nix/store 2>/dev/null || echo "Unable to calculate"
      '')

      # ===================
      # Minimal Troubleshooting Helpers (Docker + journald)
      # ===================

      (writeShellScriptBin "docker-restart" ''
        set -euo pipefail
        if [[ $# -gt 0 ]]; then
          containers="$@"
        else
          containers="${builtins.concatStringsSep " " containerNames}"
        fi
        echo "Restarting: $containers"
        sudo docker restart $containers || true
        echo "Done."
      '')

      (writeShellScriptBin "docker-ps" ''
        set -euo pipefail
        sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
      '')

      (writeShellScriptBin "docker-stats" ''
        set -euo pipefail
        sudo docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
      '')

      (writeShellScriptBin "logs" ''
        set -euo pipefail
        if [[ $# -lt 1 ]]; then
          echo "Usage: logs <container> [-f] [--tail N]"
          exit 1
        fi
        container="$1"
        shift
        sudo docker logs "$container" "$@"
      '')

      (writeShellScriptBin "journal" ''
        set -euo pipefail

        since="1 hour ago"
        if [[ $# -ge 2 && "$1" == "--since" ]]; then
          since="$2"
          shift 2
        fi

        if [[ $# -eq 0 ]]; then
          sudo journalctl --since "$since" -n 200 --no-pager
          exit 0
        fi

        for unit in "$@"; do
          echo "=== journal: $unit (since: $since) ==="
          sudo journalctl --since "$since" -u "$unit" -n 200 --no-pager
          echo ""
        done
      '')

      # OpenClaw CLI — routes through the running gateway container.
      # All commands go through docker exec so agent/session commands
      # pass through the gateway's full tool filtering pipeline.
      (writeShellScriptBin "openclaw" ''
        set -euo pipefail
        if [[ $# -eq 0 ]]; then
          echo "Usage: openclaw <command> [args]"
          echo "  openclaw agent --agent <id> --message '...'   Prompt a sub-agent"
          echo "  openclaw agents list --bindings               Show agent routing"
          echo "  openclaw gateway status                       Check gateway status"
          echo "  openclaw doctor [--fix]                       Diagnose config issues"
          echo "  openclaw sandbox explain [--agent <id>]       Show sandbox policy"
          echo "  openclaw config get tools --json              Dump tool config"
          echo "  openclaw plugins list                         List active plugins"
          echo "  openclaw docs <topic>                         Query built-in docs"
          echo "  openclaw --version                            Show version"
          exit 0
        fi

        CONTAINER="openclaw-gateway"

        if ! sudo docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
          echo "Error: $CONTAINER is not running" >&2
          exit 1
        fi

        # Allocate TTY only when stdin is a terminal
        TTY_FLAG=""
        if [ -t 0 ]; then
          TTY_FLAG="-it"
        else
          TTY_FLAG="-i"
        fi

        exec sudo docker exec $TTY_FLAG -u node "$CONTAINER" openclaw "$@"
      '')

      (writeShellScriptBin "help" ''
        echo "${settings.description} -- Management Commands"
        echo ""
        echo "Rebuild (on-device; prefer remote-* for faster builds):"
        echo "  switch           Fetch latest config, rebuild, activate now"
        echo "  upgrade          Same as switch + update nixpkgs/inputs (--upgrade)"
        echo "  boot             Fetch latest config, rebuild, activate on reboot"
        echo "  try              Fetch latest config, rebuild, activate temporarily"
        echo "  rollback         Switch to previous generation"
        echo "  cleanup          Garbage collect and optimize store"
        echo "  build-log        View last build log"
        echo "  system-info      Show system status and disk usage"
        echo ""
        echo "Services:"
        echo "  openclaw <cmd>   OpenClaw CLI (openclaw doctor, openclaw agent, ...)"
        echo ""
        echo "Troubleshooting:"
        echo "  docker-ps        List containers (docker ps)"
        echo "  docker-stats     One-shot resource snapshot (docker stats)"
        echo "  docker-restart   Restart all containers"
        echo "  logs <container> Follow or tail a container log (docker logs)"
        echo "  journal [unit]   Tail system logs (journalctl)"
        echo "  help             Show this help"
        echo ""
        echo "Container exec (shell into container, or pass a command):"
        ${builtins.concatStringsSep "\n        " (map (name: "echo \"  ${name}\"") containerNames)}
        echo ""
        echo "Remote build (from workstation, recommended):"
        echo "  ./deploy remote-switch    Build on workstation, switch immediately"
        echo "  ./deploy remote-upgrade   Update nixpkgs + build on workstation, switch"
        echo "  ./deploy remote-boot      Build on workstation, activate on reboot"
      '')
    ];
}
