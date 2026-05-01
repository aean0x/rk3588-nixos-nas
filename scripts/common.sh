#!/usr/bin/env bash
# Shared functions and settings for deploy scripts
# Sourced by ./deploy and ./scripts/*.sh

# Resolve repo root (works whether sourced from deploy or scripts/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" \
    || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load settings from settings.nix
HOST=$(grep -oP 'hostName\s*=\s*"\K[^"]+' "${REPO_ROOT}/settings.nix")
ADMIN=$(grep -oP 'adminUser\s*=\s*"\K[^"]+' "${REPO_ROOT}/settings.nix")
IP=$(grep -oP 'address\s*=\s*"\K[^"]+' "${REPO_ROOT}/settings.nix")
DESC=$(grep -oP 'description\s*=\s*"\K[^"]+' "${REPO_ROOT}/settings.nix")
SETUP_PASS=$(grep -oP 'setupPassword\s*=\s*"\K[^"]+' "${REPO_ROOT}/settings.nix")

TARGET="${ADMIN}@${HOST}.local"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==> WARNING:${NC} $*"; }
error() { echo -e "${RED}==> ERROR:${NC} $*" >&2; }

SSH_OPTS="-o StrictHostKeyChecking=accept-new"

check_aarch64_support() {
    info "Checking aarch64-linux build support..."

    [[ "$(uname -m)" == "aarch64" ]] && { info "Running on aarch64 natively"; return 0; }

    if [[ -f /proc/sys/fs/binfmt_misc/aarch64 ]] || [[ -f /proc/sys/fs/binfmt_misc/aarch64-linux ]]; then
        info "binfmt/qemu aarch64 emulation available"
        return 0
    fi

    if grep -q "aarch64-linux" ~/.config/nix/nix.conf 2>/dev/null || grep -q "aarch64-linux" /etc/nix/nix.conf 2>/dev/null; then
        info "Remote aarch64 builder configured"
        return 0
    fi

    if nix show-config 2>/dev/null | grep -q "extra-platforms.*aarch64-linux"; then
        info "aarch64-linux in extra-platforms"
        return 0
    fi

    error "No aarch64-linux build support detected."
    echo "Enable one of:"
    echo "  - binfmt/qemu: boot.binfmt.emulatedSystems = [\"aarch64-linux\"]"
    echo "  - a remote aarch64 builder in nix.buildMachines"
    exit 1
}

check_ssh() {
    # Tailscale IP is the most reliable target in router mode (WAN IP may change via DHCP)
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || true)
    local candidates=("${ADMIN}@${HOST}.local" "${ADMIN}@${IP}")
    [[ -n "$ts_ip" ]] && candidates+=("${ADMIN}@${ts_ip}")

    # Try each candidate with key auth
    for candidate in "${candidates[@]}"; do
        info "Trying ${candidate}..."
        if ssh -o ConnectTimeout=5 -o BatchMode=yes ${SSH_OPTS} "$candidate" true 2>/dev/null; then
            TARGET="$candidate"
            info "SSH connection OK (${TARGET})"
            return 0
        fi
    done

    # Prompt for manual IP
    warn "Could not reach any candidate: ${candidates[*]}"
    read -p "Enter device IP (or Ctrl+C to abort): " MANUAL_IP
    candidates+=("${ADMIN}@${MANUAL_IP}")

    # Try manual IP with key auth
    if ssh -o ConnectTimeout=5 -o BatchMode=yes ${SSH_OPTS} "${ADMIN}@${MANUAL_IP}" true 2>/dev/null; then
        TARGET="${ADMIN}@${MANUAL_IP}"
        info "SSH connection OK (${TARGET})"
        return 0
    fi

    # Retry all candidates with password auth (installer may not have keys)
    warn "Key auth failed. Trying password auth (password: ${SETUP_PASS})..."
    for candidate in "${candidates[@]}"; do
        if ssh -o ConnectTimeout=5 ${SSH_OPTS} -o PubkeyAuthentication=no "$candidate" true 2>/dev/null; then
            TARGET="$candidate"
            SSH_OPTS="${SSH_OPTS} -o PubkeyAuthentication=no"
            info "SSH connection OK via password (${TARGET})"
            return 0
        fi
    done

    error "SSH failed (tried: ${candidates[*]})"
    exit 1
}

update_flake() {
    info "Updating flake inputs..."
    nix flake update --print-build-logs
}

build_system() {
    info "Building NixOS configuration for ${HOST}..."
    info "This may take a while (cross-compiling or emulating aarch64)..."
    echo ""
    nix build ".#nixosConfigurations.${HOST}.config.system.build.toplevel" \
        --print-build-logs \
        --show-trace \
        "$@"
}

deploy_system() {
    local action="$1"

    local result_path
    result_path="$(readlink -f result)"

    if [[ "$action" == "build" ]]; then
        info "Build-only mode, skipping deployment"
        return 0
    fi

    info "Copying system closure to ${TARGET}..."
    export NIX_SSHOPTS="${SSH_OPTS}"
    nix copy --to "ssh-ng://${TARGET}?remote-program=sudo%20nix-daemon" --no-check-sigs "$result_path"

    info "Activating system (${action})..."
    if [[ "$action" == "test" ]]; then
        # Activate without setting boot default — reboot recovers previous config
        ssh -t ${SSH_OPTS} "$TARGET" "sudo \"$result_path/bin/switch-to-configuration\" test"
    else
        ssh -t ${SSH_OPTS} "$TARGET" "sudo nix-env -p /nix/var/nix/profiles/system --set \"$result_path\"; sudo \"$result_path/bin/switch-to-configuration\" \"$action\""
    fi

    info "Deployment complete!"
}
