#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Find age key
find_key() {
    if [ -f key.txt ]; then
        echo "key.txt"
    elif [ -f /var/lib/sops-nix/key.txt ]; then
        echo "/var/lib/sops-nix/key.txt"
    else
        echo ""
    fi
}

KEY_PATH=$(find_key)

# Generate new key if none exists
if [ -z "$KEY_PATH" ]; then
    echo "No key found. Generating new age key..."
    age-keygen -o key.txt
    KEY_PATH="key.txt"
    echo "Public key:"
    age-keygen -y key.txt
    echo
fi

# Offer to copy key to system location
if [ -f key.txt ] && [ ! -f /var/lib/sops-nix/key.txt ]; then
    echo "Copy key to /var/lib/sops-nix/key.txt? (required for NixOS) [y/N] "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        sudo mkdir -p /var/lib/sops-nix
        sudo cp key.txt /var/lib/sops-nix/key.txt
        sudo chmod 600 /var/lib/sops-nix/key.txt
        echo "Key copied."
    fi
fi

# Create .sops.yaml if missing
if [ ! -f .sops.yaml ]; then
    PUBLIC_KEY=$(age-keygen -y "$KEY_PATH")
    cat > .sops.yaml << EOF
creation_rules:
  - path_regex: .*secrets\.yaml(\.work)?$
    key_groups:
      - age:
          - ${PUBLIC_KEY}
EOF
    echo "Created .sops.yaml with your public key"
fi

# Fork detection: if secrets.yaml exists but cannot be decrypted with current key
if [ -f secrets.yaml ] && [ ! -f secrets.yaml.work ]; then
    echo "Found existing secrets.yaml. Testing decryption..."
    if ! SOPS_AGE_KEY_FILE="$KEY_PATH" SOPS_CONFIG="$(pwd)/.sops.yaml" sops -d secrets.yaml > /dev/null 2>&1; then
        echo ""
        echo "WARNING: Cannot decrypt secrets.yaml with your key."
        echo "This usually means you forked the repo and kept the original encrypted secrets."
        echo ""
        echo "Overwrite with secrets.yaml.example for editing? [y/N] "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            if [ -f secrets.yaml.example ]; then
                cp secrets.yaml.example secrets.yaml.work
                echo "Opening secrets.yaml.work in nano. Fill in your values, then save and exit."
                sleep 2
                nano secrets.yaml.work
            else
                echo "Error: secrets.yaml.example not found"
                exit 1
            fi
        else
            echo "Aborting. Delete secrets.yaml and try again after filling out secrets.yaml.example"
            exit 1
        fi
    else
        SOPS_AGE_KEY_FILE="$KEY_PATH" SOPS_CONFIG="$(pwd)/.sops.yaml" sops --input-type=yaml --output-type=yaml -d secrets.yaml > secrets.yaml.work
        echo "Decrypted existing secrets to secrets.yaml.work"
    fi
fi

# First run: no secrets.yaml, create from example
if [ ! -f secrets.yaml ] && [ ! -f secrets.yaml.work ]; then
    if [ -f secrets.yaml.example ]; then
        cp secrets.yaml.example secrets.yaml.work
        echo "Opening secrets.yaml.work in nano. Fill in your values, then save and exit."
        sleep 2
        nano secrets.yaml.work
    else
        echo "Error: secrets.yaml.example not found"
        exit 1
    fi
fi

# Encrypt if work file exists
if [ -f secrets.yaml.work ]; then
    SOPS_AGE_KEY_FILE="$KEY_PATH" SOPS_CONFIG="$(pwd)/.sops.yaml" sops --input-type=yaml --output-type=yaml -e secrets.yaml.work > secrets.yaml
    echo "Encrypted secrets.yaml.work -> secrets.yaml"
    rm secrets.yaml.work
else
    echo "Error: No secrets.yaml.work file found"
    exit 1
fi
