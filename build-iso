#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Check if settings.nix repoUrl matches current git remote
echo "Validating settings.nix..."
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?|\1|')
SETTINGS_REPO=$(grep -oP 'repoUrl\s*=\s*"\K[^"]+' settings.nix 2>/dev/null || echo "")

if [ -n "$CURRENT_REMOTE" ] && [ -n "$SETTINGS_REPO" ] && [ "$CURRENT_REMOTE" != "$SETTINGS_REPO" ]; then
    echo ""
    echo "WARNING: settings.nix repoUrl doesn't match your git remote."
    echo "  settings.nix: $SETTINGS_REPO"
    echo "  git remote:   $CURRENT_REMOTE"
    echo ""
    echo "Edit settings.nix now? [Y/n] "
    read -r response
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        nano settings.nix
        echo ""
        echo "Remember to commit and push to remote before building!"
        echo "Press Enter to continue or Ctrl+C to abort..."
        read -r
    fi
fi

# Ensure secrets are set up
echo "Setting up SOPS encryption..."
cd secrets
./encrypt.sh
cd ..

# Verify key exists
KEY_PATH="$(pwd)/secrets/key.txt"
if [ ! -f "$KEY_PATH" ]; then
    echo "Error: key.txt not found in secrets/"
    exit 1
fi

# Build ISO with key path for injection
export KEY_FILE_PATH="$KEY_PATH"
echo "Building ISO..."
nix build .#iso --impure

echo "ISO built: result/"
