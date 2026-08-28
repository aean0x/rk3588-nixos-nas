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
ROUTER_MODE=$(grep -oP 'enableRouter\s*=\s*\K\w+' "${REPO_ROOT}/settings.nix")
ROUTER_LAN_IP=$(grep -oP 'lanAddress\s*=\s*"\K[^"]+' "${REPO_ROOT}/hosts/system/services/router.nix" 2>/dev/null || true)

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

    # Main system / ISO / netboot set localSystem=x86_64 + crossSystem=aarch64.
    # Kernel and gcc are CROSS_COMPILE, not qemu-user. binfmt is optional.
    info "Cross-compiling aarch64 (aarch64-unknown-linux-gnu-gcc on this CPU)"
    if [[ -f /proc/sys/fs/binfmt_misc/aarch64 ]] || [[ -f /proc/sys/fs/binfmt_misc/aarch64-linux ]]; then
        info "binfmt/qemu also present (only needed if a drv must *run* aarch64 bins)"
    fi
    return 0
}

check_ssh() {
    local candidates=("${ADMIN}@${HOST}.local")

    # In router mode the static IP from settings.nix is the WAN side and
    # unreachable from the LAN — prefer the bridge gateway address.
    if [[ "$ROUTER_MODE" == "true" && -n "$ROUTER_LAN_IP" ]]; then
        candidates+=("${ADMIN}@${ROUTER_LAN_IP}")
    fi
    candidates+=("${ADMIN}@${IP}")

    # Tailscale IP as fallback
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || true)
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
    # Ryzen 7900 12c/24t ~30GiB: several aarch64 packages in flight, but
    # cap per-drv cores so one LLVM does not spawn 24 cc1plus. --keep-going
    # lets LLVM finish if a leaf (bun, ncdu, …) dies.
    local jobs="${NIX_MAX_JOBS:-8}"
    local cores="${NIX_BUILD_CORES:-12}"
    info "nix build --max-jobs ${jobs} --cores ${cores} --keep-going"
    nix build ".#nixosConfigurations.${HOST}.config.system.build.toplevel" \
        --print-build-logs \
        --show-trace \
        --keep-going \
        --max-jobs "$jobs" \
        --cores "$cores" \
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
