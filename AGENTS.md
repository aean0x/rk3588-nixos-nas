# AGENTS.md

Technical roadmap for AI agents working with this NixOS flake configuration.

## Architecture Overview

```
flake.nix                    # Entry point - three outputs: system, ISO, netboot
├── settings.nix             # All user config (hostname, network, admin user)
├── hardware-configuration.nix  # RK3588 kernel, device tree, boot params
├── deploy                   # Lean command router (sources scripts/common.sh)
├── shell.nix                # Dev shell (age, sops, rsync, dnsmasq, python3, etc.)
├── scripts/                 # All scripts (workstation + on-device)
│   ├── common.sh            # Shared: settings parsing, colors, check_ssh, build helpers
│   ├── build-iso.sh         # ISO build + USB write prompt
│   ├── build-netboot.sh     # Netboot image build only
│   ├── netboot.sh           # PXE server (dnsmasq DHCP/TFTP + HTTP), LAN or direct-connect
│   ├── install.sh           # Remote install: partition, rsync repo, nixos-install
│   └── scripts.nix          # On-device management commands (switch, help, docker-ps, etc.)
├── hosts/
│   ├── system/              # Target system (what gets installed)
│   │   ├── default.nix      # Networking, SSH, users, boot loader, WiFi, bluetooth
│   │   ├── packages.nix     # System-wide packages
│   │   ├── partitions.nix   # Filesystem mounts (label-based), ZFS config
│   │   ├── services.nix     # Service imports (uncomment to enable)
│   │   └── services/        # Service modules
│   │       ├── containers.nix   # Docker containers (HA, Matter, Tailscale, OTBR)
│   │       ├── arr-suite.nix    # nixarr media stack (Sonarr, Radarr, etc.)
│   │       ├── caddy.nix        # Reverse proxy with Cloudflare DNS ACME
│   │       ├── cockpit.nix      # Web-based system management
│   │       ├── remote-desktop.nix # XFCE + xrdp
│   │       ├── tasks.nix        # Auto-upgrade and garbage collection
│   │       └── transmission.nix # Torrent client with VPN killswitch
│   └── iso/                  # Installer image (shared by ISO + netboot)
│       └── default.nix      # Minimal env: SSH + pubkeys + avahi + rsync (no secrets)
└── secrets/                 # SOPS-encrypted secrets
    ├── sops.nix             # Secrets module (conditional WiFi, mkIf guards)
    ├── secrets.yaml         # Encrypted secrets (committed)
    ├── secrets.yaml.example # Template for new users
    ├── encrypt              # Key generation + encryption workflow
    └── decrypt              # Decrypt for editing
```

## Key Patterns

### Settings vs Secrets

**settings.nix** — Values needed at Nix eval time:
- `repoUrl` — Single string "owner/repo" for flake references
- `hostName`, `adminUser`, `setupPassword` — Must be known at build time
- `network` — Static IP config (interface, address, prefixLength, gateway, DNS)
- `enableWifi`, `wifiSsid` — Optional WiFi (PSK is a secret)
- Build systems (`hostSystem`, `targetSystem`) for cross-compilation
- `kernelPackage` — Kernel version (6.18 for rk3588)
- Service ports live in their respective modules (e.g. containers.nix let-in block)

**secrets/sops.nix** — Runtime secrets (decrypted at activation):
- `user_hashedPassword` — Login password
- `tailscale_authKey` — Tailscale auth key
- `wifi_psk` — WiFi password (conditional on `settings.enableWifi`)
- Service-specific secrets declared in their respective modules

### Flake Outputs

- `nixosConfigurations.${hostName}` — Main system (what gets installed)
- `nixosConfigurations.${hostName}-ISO` — ISO installer image
- `nixosConfigurations.${hostName}-netboot` — Netboot installer image
- `packages.${hostSystem}.iso` — ISO build artifact
- `packages.${hostSystem}.netboot` — Netboot build artifact (kernel, initrd, squashfs, snp.efi, netboot.ipxe)

ISO and netboot share `installerModules` (cross-compilation config + `hosts/iso/default.nix`). ISO-specific config (isoImage settings) is inline in flake.nix.

### Container Exec (auto-derived)

Container wrapper scripts are auto-generated from `config.virtualisation.oci-containers.containers` in `scripts.nix`:
- Each container gets a shell command: `<name>` shells in, `<name> <cmd>` runs a command
- `help` auto-lists available containers
- `deploy` catches unrecognized commands and passes through via SSH (device-side wrappers handle them)

### SSH Resolution

`check_ssh` in `common.sh` resolves the device once and sets `TARGET` + `SSH_OPTS` for the entire session:
1. Try `${ADMIN}@${HOST}.local` (mDNS) with key auth
2. Try `${ADMIN}@${IP}` (static IP from settings) with key auth
3. Prompt for manual IP, try with key auth
4. Retry all candidates with password auth (for fresh installer/netboot)

All subsequent ssh/scp/rsync calls use `$TARGET` and `$SSH_OPTS` — no redundant resolution.

### Installation Flow

Fully remote from workstation — two boot options:
1. **USB ISO**: `./deploy build-iso` — builds pure ISO, offers to write to USB
2. **PXE netboot**: `./deploy build-netboot` then `./deploy netboot` — starts PXE server with LAN proxy or direct-connect mode

Then:
3. `./deploy install` — SSH in, partition (GPT: 512M EFI + ext4 root), rsync repo + SOPS key, nixos-install from local flake (no root password)
4. Reboot — device is fully operational, sops-nix decrypts secrets on first boot
5. Subsequent updates: `./deploy remote-switch` or on-device `switch`

### PXE Netboot

Boot chain: dnsmasq(DHCP+TFTP) -> snp.efi(iPXE) -> HTTP(kernel+initrd)

Two network modes:
- **LAN proxy** — workstation and device on the same router. dnsmasq acts as DHCP proxy.
- **Direct connect** — ethernet cable between workstation and device. Full DHCP server on 192.168.100.0/24. Firewall ports opened via iptables, cleaned up on exit.

After netboot completes, plug device into router for WAN access before running `./deploy install`.

### SOPS Flow
1. `secrets/encrypt` generates age key if missing, handles fork detection
2. `secrets/decrypt` decrypts for editing
3. `./deploy install` copies key to `/var/lib/sops-nix/key.txt` during installation
4. System decrypts secrets at activation time (first real boot)
5. During `nixos-install`, "password file not found" warnings are expected — secrets materialize on boot

### Remote Flake Workflow
1. Edit config on dev machine, commit, push
2. On NAS: run `switch` (fetches from `github:owner/repo#hostname`)
3. Auto-upgrade runs weekly (Sunday 3AM) if `tasks.nix` is enabled
4. Or from workstation: `./deploy remote-switch` (builds locally, pushes closure)

## Modification Guidelines

### Adding Secrets
1. Add key to `secrets/sops.nix` secrets block (use `lib.mkIf` for conditional secrets)
2. Add placeholder to `secrets.yaml.example`
3. Run `./secrets/decrypt` → edit → `./secrets/encrypt`
4. Reference as `config.sops.secrets."key".path` in modules

### Enabling Services
1. Uncomment the import line in `hosts/system/services.nix`
2. Ensure required secrets are configured (check service file for `config.sops.secrets.*` references)
3. Commit, push, rebuild

### Adding Containers
1. Add container definition to `containers.nix` under `virtualisation.oci-containers.containers`
2. Container exec wrapper is auto-generated (no manual step needed)
3. Firewall ports: add to `networking.firewall` in the same file
4. Pull timer and restart timer auto-include all containers

## Gotchas

- ISO/netboot build requires aarch64 support (binfmt/qemu or remote builder) since target is aarch64
- `adminUser` cannot move to SOPS (needed at Nix eval time for attribute name)
- Static IP is used (no NetworkManager) — `useDHCP = false` in system config, `useDHCP = true` in installer
- Services are toggled in `hosts/system/services.nix` by uncommenting imports
- `hosts/iso/default.nix` is shared between ISO and netboot — `isoImage` config lives in flake.nix inline module
- `setupPassword` is only used in the installer, not the installed system
- Kernel 6.18 is required for rk3588 — builds are slow due to cross-compilation
- Installer image includes rsync (needed by `./deploy install`)
- `ADMIN` variable in scripts (not `USER`) to avoid shadowing shell builtin
- sops-nix warnings during `nixos-install` ("password file not found", "cannot read ssh key") are normal — secrets and host keys materialize on first real boot
