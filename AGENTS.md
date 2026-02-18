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
│   │   ├── default.nix      # Networking, SSH, users, boot loader, WiFi, bluetooth, media group
│   │   ├── packages.nix     # System-wide packages
│   │   ├── partitions.nix   # Filesystem mounts (label-based), ZFS dataset mounts
│   │   ├── services.nix     # Service imports (uncomment to enable)
│   │   ├── containers.nix   # Docker engine, refresh timer, imports containers/*
│   │   ├── containers/      # Docker container modules
│   │   │   ├── home-assistant.nix # Home Assistant, Matter Server, OTBR
│   │   │   └── filebrowser.nix    # Web-based file manager (SOPS-managed admin password)
│   │   ├── openclaw/         # OpenClaw gateway, workspace dotfiles, related services
│   │   │   ├── default.nix        # Docker containers, builder, preStart, refresh timer
│   │   │   ├── openclaw.json      # Gateway config (committed, merged into /var/lib/openclaw/)
│   │   │   ├── onedrive.nix       # OneDrive bidirectional sync into workspace
│   │   │   └── workspace/         # Nix-managed dotfiles deployed to /var/lib/openclaw/workspace/
│   │   │       ├── AGENTS.md      # Agent role descriptions and guidelines
│   │   │       ├── SOUL.md        # Personality directives
│   │   │       └── STYLE.md       # Message formatting and output rules
│   │   └── services/        # Native service modules
│   │       ├── tailscale.nix      # Tailscale VPN (native NixOS)
│   │       ├── adguard.nix        # AdGuard Home DNS (native NixOS)
│   │       ├── cloudflared.nix    # Cloudflare tunnel (native NixOS)
│   │       ├── remote-desktop.nix # XFCE + xrdp
│   │       ├── tasks.nix          # Auto-upgrade and garbage collection
│   │       └── caddy.nix          # Reverse proxy with ACME DNS-01 via Cloudflare
│   └── iso/                  # Installer image (shared by ISO + netboot)
│       ├── default.nix       # Minimal env: SSH + pubkeys + avahi + rsync (no secrets)
│       ├── iso.nix           # ISO-specific config (isoImage settings)
│       └── netboot.nix       # Netboot-specific config (placeholder)
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
- `domain` — Public domain for ACME certs (subdomains defined per-service)
- `network` — Static IP config (interface, address, prefixLength, gateway, DNS)
- `enableWifi`, `wifiSsid` — Optional WiFi (PSK is a secret)
- Build systems (`hostSystem`, `targetSystem`) for cross-compilation
- `kernelPackage` — Kernel version (6.18 for rk3588)
- Service ports live in their respective modules as `let` bindings

**secrets/sops.nix** — Runtime secrets (decrypted at activation):
- `user_hashedPassword` — Login password
- `tailscale_authKey` — Tailscale auth key
- `wifi_psk` — WiFi password (conditional on `settings.enableWifi`)
- `openclaw_gateway_token` — OpenClaw gateway authentication
- `composio_encryption_key`, `composio_jwt_secret` — Composio self-hosted secrets
- `signal_phone_number` — Signal CLI phone number
- `cloudflare_dns_api_token` — Cloudflare API token for ACME DNS-01 challenge (used by Caddy)
- `cloudflared_tunnel_credentials` — Cloudflare tunnel JSON (owned by cloudflared user)

### Service Architecture

Philosophy: **Docker for complex/dependency-heavy stacks, native NixOS for simple/well-supported services.**

| Service | Type | Module |
|---------|------|--------|
| Docker engine | Native | `containers.nix` |
| Home Assistant + Matter + OTBR | Docker | `home-assistant.nix` |
| Tailscale VPN | Native | `tailscale.nix` |
| AdGuard Home DNS | Native | `adguard.nix` |
| OpenClaw gateway + CLI | Docker | `openclaw.nix` |
| Cloudflare tunnel | Native | `cloudflared.nix` |

**containers.nix** is pure infrastructure — Docker engine, auto-prune, unified `refresh-containers` timer. It contains **no container definitions**. Container definitions live in their respective service modules.

**Auto-derived refresh**: `containerNames` and `uniqueImages` are auto-discovered from all imported modules. The single `refresh-containers` timer (Sun 02:00) pulls all images and restarts all containers. No per-service refresh timers needed.

### Docker Network Patterns

- **Host network** (`--network=host`): Used by HA, Matter, OTBR, OpenClaw for mDNS/multicast discovery

### Env Injection Pattern (preStart/postStart)

Docker containers that need sops secrets use `systemd.services.docker-<name>.preStart` to:
1. Create data directories (`mkdir -p /var/lib/...`)
2. Read secrets from sops paths (`cat ${config.sops.secrets.*.path}`)
3. Write env files to `/run/<name>.env` (mode 600)
4. Container references via `environmentFiles = [ "/run/<name>.env" ]`

### OpenClaw Docker Architecture

OpenClaw lives in `hosts/system/openclaw/` as a self-contained module. Two Docker containers (`openclaw-gateway` + `openclaw-cli`) using a custom image built at runtime on the device via `docker build`. Runs entirely non-root as `node:1000`. State at `/var/lib/openclaw/` mounted to `/home/node/.openclaw` inside containers.

- **Non-root runtime**: `user: "1000:1000"` on both containers, `--group-add=${dockerGid}` for socket access. No root anywhere in running containers.
- **`openclaw-builder`** (oneshot) — builds `openclaw-custom:latest` from upstream `ghcr.io/phioranex/openclaw-docker:latest`, adds Docker CLI (static binary) + uv, fixes `/home/linuxbrew` and `/home/node` ownership. Single-RUN layer for efficiency. Runs before gateway via `requiredBy`.
- **`preStart`** — deploys workspace dotfiles from Nix store, `chown -R 1000:1000 /var/lib/openclaw`, deep-merges committed `openclaw.json` into runtime config via jq, writes `/run/openclaw.env` with all API keys from SOPS.
- **Config as JSON**: `openclaw.json` is committed as a plain JSON file (not generated from Nix attrset). Merged over any existing runtime config on each start so manual tweaks are preserved but Nix-declared values always win.
- **Workspace dotfiles**: `workspace/AGENTS.md`, `workspace/SOUL.md`, and `workspace/STYLE.md` are Nix-managed and deployed to `/var/lib/openclaw/workspace/` on every preStart (always overwritten). Add new files to `workspaceFiles` attrset in `default.nix`.
- **Agent sandboxes** — gateway spawns sandbox containers via mounted `docker.sock`. Sandbox defaults in `openclaw.json`: `user: "1000:1000"`, `readOnlyRoot: true`, `capDrop: ["ALL"]`, bridge network, 1g memory limit. `setupCommand` runs once at sandbox creation.
- **OneDrive sync** — `onedrive.nix` (imported by openclaw `default.nix`) runs bidirectional rclone copy on a 15m timer as UID 1000. Syncs `Shared` and `Documents` into `workspace/onedrive/`.
- **`openclaw-refresh`** timer (Mon 04:00) — pulls latest base image, rebuilds custom image, restarts gateway.

### ZFS Pool

Single pool mounted at `/media` with `nofail` + `zfsutil` (boot succeeds even if pool doesn't exist):
- `/media` — `media` — General data root + state (subdirectories live under `/media`)

Manual pool creation on first boot:
```bash
zpool create -f -o ashift=12 -O compression=lz4 -O atime=off -O mountpoint=/media media mirror /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2>
```

### Flake Outputs

- `nixosConfigurations.${hostName}` — Main system (what gets installed)
- `nixosConfigurations.${hostName}-ISO` — ISO installer image
- `nixosConfigurations.${hostName}-netboot` — Netboot installer image
- `packages.${hostSystem}.iso` — ISO build artifact
- `packages.${hostSystem}.netboot` — Netboot build artifact (kernel, initrd, snp.efi, netboot.ipxe)

ISO and netboot share `installerModules` (cross-compilation config + `hosts/iso/default.nix`). ISO-specific config in `hosts/iso/iso.nix`, netboot-specific in `hosts/iso/netboot.nix`.

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

**Remote interaction policy:** agents are expected to interact with the server directly when needed (remote commands, logs, service status, container exec, rebuilds, etc.). `./deploy` is the preferred and easiest interface for remote access because it handles discovery, SSH options, and consistent command wrapping; use it by default for both read-only and sudo-level actions (e.g., `./deploy help`, `./deploy system-info`, `./deploy journal`, `./deploy switch`, `./deploy <container>`). Direct `ssh` is acceptable when necessary, but `./deploy` should be the first choice. Server is ARM64 based and may have limited resources, so avoid heavy operations directly on the device when possible (prefer `remote-switch` for rebuilds). When pulling logs, always cap output (default to `--tail 100` or `-n 100`, and only increase if needed).

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
2. On NAS: run `switch` (fetches latest config from `github:owner/repo#hostname`)
3. Auto-upgrade runs weekly (Sunday 3AM) if `tasks.nix` is enabled — updates nixpkgs inputs too
4. Or from workstation: `./deploy remote-switch` (builds locally, pushes closure)

**switch vs upgrade:**
- `switch` / `remote-switch` — fetch latest config commit, rebuild with existing flake.lock inputs
- `upgrade` / `remote-upgrade` — same + update nixpkgs/flake inputs (`--upgrade` flag)

Docker containers with static tags (`:latest`, `:stable`) are NOT re-pulled on rebuild. Per-service refresh timers (e.g., `home-assistant-refresh`) handle image updates independently.

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

### Adding Docker Containers
1. Create a new service module in `hosts/system/services/`
2. Define containers under `virtualisation.oci-containers.containers`
3. Add firewall ports in the same module
4. Add import line to `services.nix`
5. Pull timer and restart timer in `containers.nix` auto-include all containers (no manual step)
6. Container exec wrapper in `scripts.nix` auto-generates (no manual step)

### Adding Native Services
1. Create a new service module in `hosts/system/services/`
2. Use the NixOS module system (`services.<name>.enable = true`)
3. Reference sops secrets via `config.sops.secrets.*`
4. Add import line to `services.nix`

## Gotchas

- ISO/netboot build requires aarch64 support (binfmt/qemu or remote builder) since target is aarch64
- `adminUser` cannot move to SOPS (needed at Nix eval time for attribute name)
- Static IP is used (no NetworkManager) — `useDHCP = false` in system config, `useDHCP = true` in installer
- Services are toggled in `hosts/system/services.nix` by uncommenting imports
- `hosts/iso/default.nix` is shared between ISO and netboot — platform-specific config in `iso.nix`/`netboot.nix`
- `setupPassword` is only used in the installer, not the installed system
- Kernel 6.18 is required for rk3588 — builds are slow due to cross-compilation
- Installer image includes rsync (needed by `./deploy install`)
- `ADMIN` variable in scripts (not `USER`) to avoid shadowing shell builtin
- sops-nix warnings during `nixos-install` ("password file not found", "cannot read ssh key") are normal — secrets and host keys materialize on first real boot
- ZFS dataset mounts use `nofail` — boot succeeds even if pool isn't created yet
- `services.resolved.enable = false` in adguard.nix — systemd-resolved conflicts with port 53
- Cloudflared credentials must be owned by `cloudflared` user/group (set in sops.nix)
- Composio bridge network containers must all depend on `docker-network-composio.service`
- Persistent settings go in `/var/lib` — both for native services and Docker container volume mounts
