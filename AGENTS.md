# AGENTS.md

Technical roadmap for AI agents working with this NixOS flake configuration.

## Architecture Overview

```
flake.nix                    # Entry point - two outputs: system config + ISO builder
├── settings.nix             # Minimal config (hostname, adminUser, repoUrl)
├── hardware-configuration.nix  # RK3588 kernel, device tree, boot params
├── hosts/
│   ├── system/              # Target system (what gets installed)
│   │   ├── default.nix      # Boot, networking, users, SSH - imports services/*
│   │   ├── packages.nix     # System-wide packages
│   │   ├── scripts.nix      # System management scripts (rebuild, cleanup)
│   │   ├── partitions.nix   # Filesystem mounts (label-based), ZFS config
│   │   └── services/        # Optional modules (uncomment in default.nix to enable)
│   │       ├── arr-suite.nix    # nixarr media stack (Sonarr, Radarr, etc.)
│   │       ├── caddy.nix        # Reverse proxy with Cloudflare DNS ACME
│   │       ├── cockpit.nix      # Web-based system management
│   │       ├── containers.nix   # Docker + Podman configuration
│   │       ├── remote-desktop.nix # XFCE + xrdp
│   │       ├── tasks.nix        # Auto-upgrade and garbage collection
│   │       └── transmission.nix # Torrent client with VPN killswitch
│   └── iso/                  # Installer image
│       ├── default.nix      # Cross-compilation setup, SOPS key injection
│       └── install.nix      # Installer script
└── secrets/                 # SOPS-encrypted secrets
    ├── sops.nix             # Centralized secrets module (imported by system)
    ├── secrets.yaml         # Encrypted secrets (committed)
    ├── secrets.yaml.example # Template for new users
    ├── encrypt           # Key generation + encryption workflow
    └── decrypt           # Decrypt for editing
```

## Build Targets

- `./build-iso` - Validates settings, sets up SOPS, builds ISO with `--impure`
- `nix build .#iso` - Direct ISO build (requires KEY_FILE_PATH env var)

## Key Patterns

### Settings vs Secrets

**settings.nix** - Values needed at Nix eval time:
- `repoUrl` - Single string "owner/repo", parsed into repoOwner/repoName
- `hostName`, `adminUser` - Must be known at build time
- `setupPassword` - Temp password for ISO SSH access
- Build systems (hostSystem, targetSystem)

**secrets/sops.nix** - Runtime secrets (decrypted at activation):
- `user.hashedPassword` - Login password
- `user.pubKey` - SSH authorized key
- `vpn.wgConf` - WireGuard config for VPN
- `services.transmission.credentials` - Transmission RPC auth
- `services.caddy.cloudflareToken` - Cloudflare API token (if using caddy)

### SOPS Flow
1. `build-iso` validates repoUrl matches git remote, prompts to edit if not
2. `encrypt` detects forked repos (can't decrypt existing secrets.yaml)
3. Offers to overwrite with example, opens nano for editing
4. Generates age key if missing, encrypts to secrets.yaml
5. `build-iso` embeds key in ISO via `KEY_FILE_PATH` env var
6. Installer copies key to `/mnt/var/lib/sops-nix/key.txt`
7. System decrypts secrets at activation time

### Remote Flake Workflow
1. Edit config on dev machine, commit, push
2. On NAS: run `rebuild` (fetches from `github:owner/repo#hostname`)
3. Auto-upgrade runs weekly (Sunday 3AM) if `tasks.nix` is enabled

## Modification Guidelines

### Adding Secrets
1. Add key to `secrets/sops.nix` secrets block
2. Add placeholder to `secrets.yaml.example`
3. Run `./secrets/decrypt` → edit → `./secrets/encrypt`
4. Reference as `config.sops.secrets."path".path` in modules

### Enabling Services
1. Uncomment the import line in `hosts/system/default.nix`
2. Ensure required secrets are configured (check service file for `config.sops.secrets.*` references)
3. Commit, push, rebuild

### Forking for Your Own Use
1. Fork repo, clone locally
2. Run `./build-iso` - will detect mismatched repoUrl and prompt to edit settings.nix
3. `encrypt` detects foreign secrets, prompts to overwrite with example
4. Fill in your secrets in nano when prompted
5. Commit changes, build completes

## Installation Flow

1. `build-iso` → ISO with embedded SOPS key
2. Boot ISO, SSH as `setup` (password: `nixos` or as set in settings.setupPassword)
3. Run `sudo nixinstall`
4. Select target device (GPT, optional EMMC boot)
5. Installer creates labeled partitions: `EFI`, `ROOT`
6. Copies SOPS key to `/mnt/var/lib/sops-nix/key.txt`
7. Installs from remote flake (no generated config needed)
8. Reboot into installed system

## Gotchas

- ISO build requires `--impure` for SOPS key injection via `builtins.getEnv`
- `adminUser` cannot move to SOPS (needed at Nix eval time for attribute name)
- ISO uses password auth only; installed system uses SOPS `user.pubKey`
- VPN killswitch: Transmission traffic only flows if tunnel is active
- Filesystem mounts use labels (`ROOT`, `EFI`) - no hardware-configuration.nix generation needed
- Service files need `settings` in function args if they reference `settings.adminUser`
