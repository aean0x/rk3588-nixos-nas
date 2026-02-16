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
      # Apply configuration immediately
      (writeShellScriptBin "switch" ''
        set -euo pipefail
        echo "=== Switch started at $(date) ===" | tee "${logFile}"
        echo "Rebuilding from ${flakeRef}..." | tee -a "${logFile}"
        sudo nixos-rebuild switch --flake "${flakeRef}" "$@" 2>&1 | tee -a "${logFile}"
        echo "Switch complete at $(date)" | tee -a "${logFile}"
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

      # Update flake inputs only (no rebuild)
      (writeShellScriptBin "update" ''
        set -euo pipefail
        echo "=== Flake update started at $(date) ===" | tee "${logFile}"
        cd /etc/nixos 2>/dev/null || { echo "No /etc/nixos — run from a flake checkout"; exit 1; }
        sudo nix flake update 2>&1 | tee -a "${logFile}"
        echo "Flake inputs updated at $(date). Run 'switch' to apply." | tee -a "${logFile}"
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
        containers="${builtins.concatStringsSep " " containerNames}"
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

      # OpenClaw CLI (ephemeral container, one-shot)
      (writeShellScriptBin "oc" ''
        set -euo pipefail
        if [[ $# -eq 0 ]]; then
          echo "Usage: oc <command> [args]"
          echo "  oc wizard              Initial setup wizard"
          echo "  oc gateway status      Check gateway status"
          echo "  oc doctor --fix        Fix config issues"
          echo "  oc channels add ...    Add a channel"
          echo "  oc --version           Show version"
          exit 0
        fi
        exec sudo docker run --rm -it \
          --network=host \
          --user=root \
          -e HOME=/home/node \
          --env-file /run/openclaw.env \
          -v /var/lib/openclaw:/home/node/.openclaw:rw \
          ghcr.io/openclaw/openclaw:latest \
          node dist/index.js "$@"
      '')

      (writeShellScriptBin "help" ''
        echo "${settings.description} -- Management Commands"
        echo ""
        echo "On-device (runs on the Pi; may be sluggish on resource-constrained hardware):"
        echo "  switch           Apply configuration immediately (nixos-rebuild switch)"
        echo "  boot             Apply on next reboot (nixos-rebuild boot)"
        echo "  try              Apply temporarily (nixos-rebuild test)"
        echo "  update           Update flake inputs (no rebuild)"
        echo "  rollback         Rollback to previous generation"
        echo "  cleanup          Garbage collect and optimize store"
        echo "  build-log        View last build log"
        echo "  system-info      Show system status and disk usage"
        echo ""
        echo "Services:"
        echo "  oc <cmd> [args]  OpenClaw CLI (oc wizard, oc gateway status, ...)"
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
        echo "Remote build (recommended if switch/boot/try is slow or hits OOM):"
        echo "  ./deploy remote-switch   Build on workstation, switch immediately"
        echo "  ./deploy remote-boot     Build on workstation, activate on reboot"
      '')
    ];
}
