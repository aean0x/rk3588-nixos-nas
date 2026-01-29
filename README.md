# Rock 5 NAS

A NixOS configuration for the ROCK5 ITX board, featuring automated installation and secure secrets management.

## Prerequisites

- A Linux system with Nix installed
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
   - `repoUrl` - Your fork (e.g., `"your-username/rock-5-nas"`)
   - `hostName` - System hostname (default: `rock-5-nas`)
   - `adminUser` - Your username

4. **Configure Secrets**
   
   Secrets are encrypted with SOPS and safe to commit publicly. Edit on your workstation:
   ```bash
   cd secrets
   ./encrypt
   ```
   This generates an encryption key, opens `secrets.yaml.work` in nano, and encrypts on save.

   Required values (see `secrets.yaml.example` for full schema):
   - `user.hashedPassword` - Generate with `mkpasswd -m SHA-512`
   - `user.pubKey` - Your SSH public key from step 2

5. **Commit and Push**
   ```bash
   git add .
   git commit -m "Initial configuration"
   git push
   ```

## Bootloader Configuration

Flash the EDK2 UEFI firmware before building the ISO.

1. **Download Required Files**
   - [rk3588_spl_loader_v1.15.113.bin](https://dl.radxa.com/rock5/sw/images/loader/rk3588_spl_loader_v1.15.113.bin) - SPI bootloader
   - [rock-5-itx_UEFI_Release](https://github.com/edk2-porting/edk2-rk3588/releases/) - UEFI image (select "rock-5-itx")

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

## Building the ISO

1. **Build**
   ```bash
   ./build-iso
   ```

2. **Write to USB**
   ```bash
   sudo dd if="$(ls result/iso/*.iso)" of=/dev/sda bs=4M status=progress && sync
   ```

## Installation

1. **Boot from USB** on your ROCK5 ITX

2. **Connect via SSH**
   ```bash
   ssh your_username@rock-5-nas.local
   # Password: nixos (or as configured in settings.setupPassword)
   ```

3. **Run the Installer**
   ```bash
   sudo nixinstall
   ```

4. **First Boot**
   
   Remove installation media and reboot. Connect with your SSH key:
   ```bash
   ssh your_username@rock-5-nas.local
   ```

## System Management

### Remote Deployment

Deploy changes from your workstation via `./deploy <command>`:

```bash
./deploy rebuild        # Rebuild from remote flake
./deploy rebuild-update # Update flake inputs and rebuild
./deploy rebuild-reboot # Rebuild and reboot
./deploy rebuild-log    # View last rebuild log
./deploy system-info    # Show system status
./deploy help           # List all commands
./deploy ssh            # Interactive session
```

### Available Commands

Run directly on the NAS or remotely via `deploy`:

| Command | Description |
|---------|-------------|
| `rebuild` | Rebuild system from remote flake |
| `rebuild-boot` | Rebuild, apply on next reboot |
| `rebuild-reboot` | Rebuild and reboot immediately |
| `rebuild-update` | Update flake inputs and rebuild |
| `rebuild-log` | View last rebuild log |
| `rollback` | Rollback to previous generation |
| `cleanup` | Garbage collect and optimize store |
| `system-info` | Show system status and disk usage |
| `nas-help` | List available commands |

### Editing Secrets

On your workstation (secrets cannot be decrypted on the NAS without the key):
```bash
cd secrets
./decrypt          # Decrypt to secrets.yaml.work
nano secrets.yaml.work
./encrypt          # Re-encrypt changes
```
Commit, push, and `rebuild` to apply.

### Enabling Services

Optional service modules are in `hosts/system/services/`. Enable by uncommenting imports in `hosts/system/default.nix`:

```nix
imports = [
  # ...
  # ./services/cockpit.nix      # Web-based system management (port 9090)
  # ./services/caddy.nix        # Reverse proxy with automatic HTTPS
  # ./services/containers.nix   # Docker + Podman
  # ./services/arr-suite.nix    # Media stack (Sonarr, Radarr, Jellyfin, etc.)
  # ./services/transmission.nix # Torrent client with VPN killswitch
  ./services/remote-desktop.nix # XFCE + xrdp (enabled by default)
  ./services/tasks.nix          # Auto-upgrade and garbage collection
];
```

Some services require secrets — check the service file for `config.sops.secrets.*` references and ensure matching entries exist in your `secrets.yaml`.

## Notable Features

- **ZFS Support** - Auto-scrub, snapshots, and trim enabled by default. Pools auto-import.
- **VPN Killswitch** - Transmission routes only through WireGuard tunnel (requires `vpn.wgConf` secret)
- **mDNS** - System broadcasts `hostname.local` for easy discovery
- **Remote Flake** - No local config needed on NAS; rebuilds fetch directly from GitHub
- **Cross-compilation** - ISO builds on x86_64 for aarch64 target
