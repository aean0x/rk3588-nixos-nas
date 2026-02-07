# Rock 5 NAS

A NixOS configuration for the ROCK5 ITX board, featuring fully remote installation and secure secrets management.

## Prerequisites

- A Linux system with Nix installed
- aarch64-linux build support (binfmt/qemu or remote builder)
- Git
- SSH key pair

## Initial Setup

1. **Fork and Clone**
   ```bash
   git clone https://github.com/YOUR_USERNAME/rock-5-nas.git
   cd rock-5-nas
   ```

2. **Generate SSH Key** (if needed)
   ```bash
   ssh-keygen -t ed25519 -C "your_email@example.com"
   cat ~/.ssh/id_ed25519.pub
   ```

3. **Configure Settings**
   
   Edit `settings.nix`:
   - `repoUrl` — Your fork (e.g., `"your-username/rock-5-nas"`)
   - `hostName` — System hostname (default: `rock-5-nas`)
   - `adminUser` — Your username
   - `sshPubKeys` — Your SSH public key(s)
   - `network` — Static IP, gateway, DNS for your LAN
   - `timeZone` — Your timezone

4. **Configure Secrets**
   
   Secrets are encrypted with SOPS and safe to commit publicly:
   ```bash
   cd secrets
   ./encrypt
   ```
   This generates an encryption key, opens `secrets.yaml.work` in nano, and encrypts on save.

   Required values (see `secrets.yaml.example`):
   - `user_hashedPassword` — Generate with `mkpasswd -m SHA-512`
   - `tailscale_authKey` — From [Tailscale admin](https://login.tailscale.com/admin/settings/keys)

5. **Commit and Push**
   ```bash
   git add .
   git commit -m "Initial configuration"
   git push
   ```

## Bootloader Configuration

Flash the EDK2 UEFI firmware before installing.

1. **Download Required Files**
   - [rk3588_spl_loader_v1.15.113.bin](https://dl.radxa.com/rock5/sw/images/loader/rk3588_spl_loader_v1.15.113.bin)
   - [rock-5-itx_UEFI_Release](https://github.com/edk2-porting/edk2-rk3588/releases/) (select "rock-5-itx")

2. **Flash the Bootloader**
   ```bash
   nix-shell -p rkdeveloptool
   sudo rkdeveloptool db rk3588_spl_loader_v1.15.113.bin
   sudo rkdeveloptool wl 0 rock-5-itx_UEFI_Release_vX.XX.X.img
   sudo rkdeveloptool rd
   ```

3. **Configure UEFI Settings**
   - Press `Escape` during boot to enter UEFI settings
   - Navigate to `ACPI / Device Tree`
   - Enable `Support DTB override & overlays`

## Installation

Two options to boot the installer:

### Option A: USB ISO

1. Build the ISO:
   ```bash
   ./deploy build-iso
   ```
2. Write to USB (the script offers to do this automatically)
3. Boot from USB on your ROCK5 ITX

### Option B: PXE Netboot

No USB drive needed — boots over ethernet from your workstation.

1. Build the netboot images:
   ```bash
   ./deploy build-netboot
   ```
2. Start the PXE server:
   ```bash
   ./deploy netboot
   ```
   Choose **LAN mode** (device on same network) or **Direct mode** (ethernet cable between workstation and device).
3. On the Rock 5 ITX: power on, press Escape, Boot Manager > UEFI PXE IPv4

### Install

Once the device is booted (ISO or netboot) and on the network:

```bash
./deploy install
```

This will:
- SSH into the device (tries mDNS, static IP, or prompts for manual IP)
- Partition the target disk (GPT: 512M EFI + ext4 root)
- Copy the configuration and SOPS key
- Run `nixos-install`

Reboot the device and it's ready.

## System Management

All management is done via `./deploy <command>`:

```bash
# Connection
./deploy ssh              # Interactive SSH
./deploy help             # List device commands

# On-device lifecycle
./deploy switch           # Rebuild from remote flake
./deploy boot             # Rebuild, activate on reboot
./deploy try              # Rebuild, activate temporarily
./deploy update           # Update flake inputs and rebuild
./deploy rollback         # Roll back to previous generation
./deploy cleanup          # Garbage collect and optimize store
./deploy system-info      # Show system status

# Workstation remote-build (recommended for low-memory devices)
./deploy remote-switch    # Build on workstation, deploy and switch
./deploy remote-boot      # Build on workstation, activate on reboot
./deploy remote-try       # Build on workstation, activate temporarily
./deploy remote-dry       # Dry run
./deploy remote-build     # Build only

# Diagnostics
./deploy docker-ps        # List containers
./deploy docker-stats     # One-shot resource snapshot
./deploy logs <container> # Tail container logs
./deploy journal [unit]   # Tail system logs
```

### Container Exec

Any running container name can be used as a command:
```bash
./deploy home-assistant              # Shell into container
./deploy home-assistant cat /config  # Run a command
./deploy docker-ps                   # List running containers
```

### Editing Secrets

On your workstation:
```bash
cd secrets
./decrypt          # Decrypt to secrets.yaml.work
nano secrets.yaml.work
./encrypt          # Re-encrypt changes
```
Commit, push, and `switch` to apply.

### Enabling Services

Optional service modules are in `hosts/system/services/`. Enable by uncommenting imports in `hosts/system/services.nix`:

```nix
imports = [
  # ./services/cockpit.nix      # Web-based system management (port 9090)
  # ./services/caddy.nix        # Reverse proxy with automatic HTTPS
  ./services/containers.nix     # Docker containers (HA, Matter, Tailscale)
  ./services/remote-desktop.nix # XFCE + xrdp
  ./services/tasks.nix          # Auto-upgrade and garbage collection
  # ./services/arr-suite.nix    # Media stack (Sonarr, Radarr, Jellyfin)
  # ./services/transmission.nix # Torrent client with VPN killswitch
];
```

## Notable Features

- **Fully Remote Install** — Boot via USB or PXE netboot, `./deploy install` does everything over SSH
- **PXE Netboot** — No USB needed. Direct-connect mode for setups without a shared LAN
- **ZFS Support** — Auto-scrub, snapshots, and trim enabled by default
- **mDNS** — System broadcasts `hostname.local` for easy discovery
- **Remote Flake** — Rebuilds fetch directly from GitHub
- **Cross-compilation** — Builds on x86_64 for aarch64 target
- **Auto-derived container exec** — Container shortcuts generated from config
- **SOPS Secrets** — Encrypted at rest, decrypted at boot, safe to commit publicly
