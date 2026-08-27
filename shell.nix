# Development shell for NixOS configuration management
# Usage: nix-shell
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Secrets management (encrypt/decrypt)
    age
    sops

    # Remote deployment
    openssh
    rsync

    # Build tools
    nix
    git

    # Used in scripts
    gnugrep
    gnused
    coreutils
    bash

    # PXE netboot server
    dnsmasq
    python3

    # PR lint gate (statix.toml)
    statix
  ];

  shellHook = ''
    echo "ROCK5 ITX NAS development shell"
    echo ""
    echo "Available commands:"
    echo "  ./deploy <cmd>        - Unified management (build-iso, netboot, install, remote-build, etc.)"
    echo "  ./secrets/encrypt     - Encrypt secrets"
    echo "  ./secrets/decrypt     - Decrypt secrets for editing"
    echo "  statix check .        - Nix lint (PR merge gate)"
    echo ""
  '';
}
