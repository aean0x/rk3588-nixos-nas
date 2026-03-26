_Maintained and actively run by me (aean0x) on a live home server. This is a battle-tested one-stop headless NixOS setup for the Rock 5 ITX board: full operation (including SSH in USB live boot) with zero keyboard or mouse required. My config is modularly imported; comment out anything you don’t want and use the rest as a solid baseline. It all just works. Have fun!_

# Rock 5 NAS

A NixOS flake for the ROCK5 ITX board - fully remote installation, SOPS secrets, Docker containers, and AI agent orchestration.

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
   - `repoUrl` - Your fork (e.g., `"your-username/rock-5-nas"`)
   - `hostName` - System hostname (default: `rock-5-nas`)
   - `adminUser` - Your username
   - `sshPubKeys` - Your SSH public key(s)
   - `network` - Static IP, gateway, DNS for your LAN
   - `domain` - Public domain for HTTPS subdomains (e.g., `"example.io"`)
   - `timeZone` - Your timezone

4. **Configure Secrets**

   Secrets are encrypted with SOPS and safe to commit publicly:
   ```bash
   cd secrets
   ./encrypt
   ```
   This generates an age encryption key, opens `secrets.yaml.work` in nano, and encrypts on save.

   Required values (see `secrets.yaml.example`):
   - `user_hashedPassword` - Generate with `mkpasswd -m SHA-512`
   - `tailscale_authKey` - From [Tailscale admin](https://login.tailscale.com/admin/settings/keys)

   Additional secrets are required per-service. Each service module references its secrets via `config.sops.secrets.*` - check the module file for what's needed.

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

No USB drive needed - boots over ethernet from your workstation.

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

```
Connection:
  ssh                  Interactive SSH
  help                 Show on-device commands

First-time setup:
  build-iso            Build bootable ISO image
  build-netboot        Build netboot images
  netboot              Start PXE server (builds if needed)
  install              Remote install (boot ISO/netboot first)

On-device lifecycle (runs on device via SSH):
  switch               Fetch latest config, rebuild, activate now
  upgrade              Same as switch + update nixpkgs/inputs + refresh containers
  boot                 Fetch latest config, rebuild, activate on reboot
  try                  Fetch latest config, rebuild, activate temporarily
  rollback             Roll back to previous system generation
  cleanup              Garbage collect and optimize store
  build-log            View last build log
  system-info          Show system status and disk usage

Workstation remote-build (recommended for low-memory devices):
  remote-switch        Build on workstation, push closure, activate now
  remote-upgrade       Update flake inputs, build, push, activate + refresh containers
  remote-boot          Build on workstation, push, activate on reboot
  remote-try           Build on workstation, push, activate temporarily
  remote-dry           Build on workstation, dry run (no activation)
  remote-build         Build on workstation only (no push)

Services:
  openclaw <cmd>       OpenClaw CLI (openclaw doctor, openclaw agent, ...)
  onedrive-sync        Trigger OneDrive sync now

Troubleshooting:
  docker-ps            List containers
  docker-stats         One-shot resource snapshot
  docker-restart       Restart all (or named) containers
  logs <container>     Tail container logs
  journal [unit]       Tail system logs
```

### Container Exec

Any running container name can be used as a command:
```bash
./deploy home-assistant              # Shell into container
./deploy home-assistant cat /config  # Run a command
./deploy docker-ps                   # List running containers
```

Container wrappers are auto-generated from the declared container set - no manual registration needed.

### Switch vs Upgrade

- **switch** / **remote-switch** - Fetch latest config commit, rebuild with existing `flake.lock` inputs. Fast, no network pulls beyond config.
- **upgrade** / **remote-upgrade** - Same as switch + update nixpkgs and flake inputs + pull latest Docker images and restart containers. Use when you want the full stack updated.

### Editing Secrets

On your workstation:
```bash
cd secrets
./decrypt          # Decrypt to secrets.yaml.work
nano secrets.yaml.work
./encrypt          # Re-encrypt changes
```
Commit, push, and `switch` to apply.

## Services

Services are toggled by uncommenting imports in `hosts/system/services.nix`:

```nix
imports = [
  ./services/tailscale.nix      # Tailscale VPN
  ./services/caddy.nix          # Reverse proxy with Cloudflare HTTPS
  ./services/adguard.nix        # AdGuard Home DNS (port 53, web UI 3000)
  ./services/remote-desktop.nix # XFCE + xrdp
  # ./services/cockpit.nix      # Web-based system management (port 9090)
  # ./services/cloudflared.nix  # Cloudflare tunnel
  # ./services/arr-suite.nix    # Media stack (Sonarr, Radarr, Jellyfin, etc.)
  # ./services/transmission.nix # Torrent client with VPN killswitch
];
```

Docker containers are imported separately via `containers.nix`:
- **Home Assistant** + Matter Server + OpenThread Border Router
- **FileBrowser** - Web file manager at `files.<domain>`, backed by SOPS-managed admin password
- **OpenClaw** - AI agent gateway with sandbox containers (see below)

### Caddy Reverse Proxy

Caddy is built with the `caddy-dns/cloudflare` plugin for automatic HTTPS via DNS-01 challenge. Service modules register subdomains through a custom NixOS option:

```nix
services.caddy.proxyServices."app.example.io" = 8080;
```

Each entry auto-generates HTTP-to-HTTPS redirect and reverse proxy vhosts. The Cloudflare DNS API token is injected from SOPS at runtime.

### OneDrive Sync

Bidirectional sync between OneDrive and the OpenClaw workspace via rclone. Runs every 15 minutes as UID 1000. Syncs `Shared` and `Documents` folders into `workspace/onedrive/`. Trigger manually with `./deploy onedrive-sync`.

### OpenClaw

Multi-agent AI system running as a Docker-based gateway that spawns sandbox containers for sub-agents. Custom Docker image built on-device adds Docker CLI, uv, git, and common tools. The `openclaw` command routes through the running gateway container:

```bash
./deploy openclaw doctor --fix       # Fix config issues
./deploy openclaw gateway status     # Check gateway health
./deploy openclaw agent --agent scout --message "..."  # Prompt a sub-agent
```

Configuration lives in `openclaw.json` (committed with secret placeholders) and workspace dotfiles in `openclaw/workspace/`. See `AGENTS.md` for architecture details.

## Notable Features

- **Fully Remote Install** - Boot via USB or PXE netboot, `./deploy install` does everything over SSH
- **PXE Netboot** - No USB needed. Direct-connect mode for setups without a shared LAN
- **ZFS Support** - Auto-scrub, snapshots, and trim enabled by default
- **mDNS** - System broadcasts `hostname.local` for easy discovery
- **Remote Flake** - On-device rebuilds fetch directly from GitHub
- **Cross-compilation** - Builds on x86_64 for aarch64 target
- **Auto-derived container exec** - Container shortcuts generated from config
- **SOPS Secrets** - Encrypted at rest, decrypted at boot, safe to commit publicly
- **Caddy + Cloudflare HTTPS** - Automatic TLS via DNS-01, subdomains declared per-service
- **Container Refresh** - Weekly timer pulls latest images; `upgrade`/`remote-upgrade` triggers it on demand
- **OneDrive Integration** - Bidirectional sync into OpenClaw workspace on a 15-minute timer
- **Auto-upgrade** - Weekly unattended rebuild (Sunday 3AM) with automatic reboot if needed
