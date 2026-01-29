# System management scripts
# Commands are discoverable via `nas-help` and remotely via `deploy`
{ pkgs, settings, ... }:

let
  flakeRef = "github:${settings.repoOwner}/${settings.repoName}#${settings.hostName}";
  logFile = "$HOME/.rebuild-log";
in
{
  environment.systemPackages = with pkgs; [
    # Rebuild system from remote flake
    (writeShellScriptBin "rebuild" ''
      set -euo pipefail
      echo "=== Rebuild started at $(date) ===" | tee "${logFile}"
      echo "Rebuilding from ${flakeRef}..." | tee -a "${logFile}"
      sudo nixos-rebuild switch --flake "${flakeRef}" "$@" 2>&1 | tee -a "${logFile}"
      echo "Rebuild complete at $(date)" | tee -a "${logFile}"
    '')

    # Rebuild and apply on next reboot
    (writeShellScriptBin "rebuild-boot" ''
      set -euo pipefail
      echo "=== Rebuild (boot) started at $(date) ===" | tee "${logFile}"
      echo "Rebuilding from ${flakeRef}..." | tee -a "${logFile}"
      sudo nixos-rebuild boot --flake "${flakeRef}" "$@" 2>&1 | tee -a "${logFile}"
      echo "Rebuild complete at $(date). Reboot to apply." | tee -a "${logFile}"
    '')

    # Rebuild and reboot immediately
    (writeShellScriptBin "rebuild-reboot" ''
      set -euo pipefail
      echo "=== Rebuild+reboot started at $(date) ===" | tee "${logFile}"
      echo "Rebuilding from ${flakeRef}..." | tee -a "${logFile}"
      sudo nixos-rebuild boot --flake "${flakeRef}" "$@" 2>&1 | tee -a "${logFile}"
      echo "Rebooting..." | tee -a "${logFile}"
      sudo reboot
    '')

    # Update flake inputs and rebuild
    (writeShellScriptBin "rebuild-update" ''
      set -euo pipefail
      echo "=== Rebuild+update started at $(date) ===" | tee "${logFile}"
      echo "Rebuilding from ${flakeRef} with --refresh..." | tee -a "${logFile}"
      sudo nixos-rebuild switch --flake "${flakeRef}" --refresh "$@" 2>&1 | tee -a "${logFile}"
      echo "Rebuild complete at $(date)" | tee -a "${logFile}"
    '')

    # View last rebuild log
    (writeShellScriptBin "rebuild-log" ''
      if [[ -f "${logFile}" ]]; then
        cat "${logFile}"
      else
        echo "No rebuild log found at ${logFile}"
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
      echo "=== Disk Usage ==="
      df -h / /nix 2>/dev/null || df -h /
      echo ""
      echo "=== Store Size ==="
      du -sh /nix/store 2>/dev/null || echo "Unable to calculate"
    '')

    # List available NAS management commands (used by deploy)
    (writeShellScriptBin "nas-help" ''
      echo "NAS Management Commands:"
      echo ""
      echo "  rebuild        Rebuild system from remote flake"
      echo "  rebuild-boot   Rebuild, apply on next reboot"
      echo "  rebuild-reboot Rebuild and reboot immediately"
      echo "  rebuild-update Update flake inputs and rebuild"
      echo "  rebuild-log    View last rebuild log"
      echo "  rollback       Rollback to previous generation"
      echo "  cleanup        Garbage collect and optimize store"
      echo "  system-info    Show system status and disk usage"
      echo "  nas-help       Show this help"
    '')
  ];
}
