# AGENTS.md

Technical roadmap for AI agents working with this NixOS flake configuration.

## Entry Point

**`./deploy` is the primary interface for all server interactions** — SSH, log inspection, container management, builds, and deployments. Run `./deploy` with no arguments to see all available commands.

### Git identity (mandatory)

Commits use **only** `aean0x <3682177+aean0x@users.noreply.github.com>` (this machine's `git config user.name` / `user.email`). Do not override `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, do not add Claude/Copilot/agent `Co-authored-by` trailers, do not commit as a bot, and never commit as `agent@local` / `hermes@local` / `hermes@rocknas.local`.

### Agent autonomy (mandatory)

Agents working this repo are **expected to drive `./deploy` themselves** to complete goals end-to-end — do not stop and hand the user a checklist of deploy steps when `./deploy` can do them. Treat the workstation + device as one loop: edit → `git add` (flakes) → `./deploy remote-test|remote-switch` → `./deploy journal` / `./deploy validate-gbrain` / `./deploy hermes …` → fix → repeat.

- Prefer **`./deploy …` over raw `ssh`/`scp`/`docker`** so discovery, SSH opts, and command wrapping stay consistent.
- Prefer **`remote-test` while iterating**; use **`remote-switch`** (or `remote-upgrade` when inputs must move) for durable activation. Reboot recovers the previous generation after a bad `remote-test`.
- Use **`./deploy hermes <cmd>`**, **`./deploy validate-gbrain`**, **`./deploy journal hermes-agent`**, **`./deploy logs hermes-agent`** for Hermes/GBrain work without waiting on the user to run them.
- Cap log pulls (`-n 100` / `--tail 100`). The NAS is ARM64 with limited RAM — build on the workstation via `remote-*`, not on-device, unless the user asks otherwise.
- Only pause for the user when something is truly blocked (missing secret value, physical USB, irreversible product choice with no default). Long builds are not a reason to stop: monitor, then resume.

Key subcommands:
- `./deploy ssh` — interactive shell on the device
- `./deploy journal [unit]` — tail system/unit logs
- `./deploy remote-test` — build on workstation, activate without setting boot default (safe)
- `./deploy remote-switch` — build on workstation, activate and set as boot default
- `./deploy remote-upgrade` — same as remote-switch + update flake inputs (long; may rebuild kernel)
- `./deploy logs <container>` — tail a Docker container's logs
- `./deploy hermes <cmd>` — Hermes CLI on the device (chat, doctor, gateway, …)
- `./deploy validate-gbrain` / `gbrain-setup` / `clean-hermes-state` — GBrain ops (HTTP sole-owner + two plugins; no exclusive CLI)
- `./deploy <container>` — exec into a container

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
│   └── scripts.nix          # On-device management commands (switch, help, docker-ps, oc, etc.)
├── hosts/
│   ├── system/              # Target system (what gets installed)
│   │   ├── default.nix      # Networking, SSH, users, boot loader, bluetooth
│   │   ├── packages.nix     # System-wide packages
│   │   ├── partitions.nix   # Filesystem mounts (label-based), 8G swapfile, btrfs media
│   │   ├── tasks.nix        # Auto-upgrade (Sun 03:00) and garbage collection
│   │   ├── services.nix     # Service imports (uncomment to enable)
│   │   ├── containers.nix   # Docker engine, refresh timer, imports containers/*
│   │   ├── containers/      # Docker container modules
│   │   │   ├── home-assistant.nix # Home Assistant, Matter Server, OTBR
│   │   │   ├── filebrowser.nix    # (disabled) legacy web file manager
│   │   │   └── crowdsec.nix       # CrowdSec IDS/IPS engine + native nftables bouncer
│   │   ├── hermes/          # Hermes consumer (hermes.nix) + host leftovers
│   │   └── services/        # Native service modules
│   │       ├── tailscale.nix      # Tailscale VPN (native NixOS)
│   │       ├── adguard.nix        # AdGuard Home DNS (native NixOS)
│   │       ├── cloudflared.nix    # Cloudflare tunnel (native NixOS)
│   │       ├── remote-desktop.nix # XFCE + xrdp
│   │       └── caddy.nix         # Reverse proxy with ACME DNS-01 via Cloudflare
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
- `xai_api_key` — xAI/Grok model API key
- `openrouter_api_key`, `anthropic_api_key`, `deepseek_api_key` — LLM provider keys
- `brave_search_api_key`, `google_api_key`, `google_places_api_key` — Search/maps
- `browserless_api_token` — Remote browser CDP service (Browserless cloud; good for soft CF, weak alone on AXS-class ticketing)
- Local browser: `services.hermesPnP.browser` (declared in `hosts/system/hermes/hermes.nix`, Brave engine) — sticky profile `/var/lib/hermes/browser-profile`, CDP `127.0.0.1:9222`, **agent-browser gate on :4848** (`https://browser.<domain>/`, LAN/Tailscale, no Cloudflare tunnel). Primary for checkout; Browserless is secondary scraping only.
- `telegram_bot_token`, `telegram_admin_id` — Telegram bot + admin allowlist
- `composio_api_key` — hermes-pnp mcp-proxy injects Composio MCP Bearer; also Hermes env for API
- `ha_token`, `ha_url` — Home Assistant API
- `cloudflare_dns_api_token` — Cloudflare API for ACME DNS-01 challenge
- `filebrowser_password` — FileBrowser admin password
- `onedrive_rclone_config` — rclone config for OneDrive sync (mode 0444)
- `cloudflared_tunnel_credentials` — Cloudflare Tunnel credentials JSON (from `./scripts/setup-cloudflare-tunnel.sh`)
- `nix_pc_agent_ssh_key` — Hermes → workstation `agent` SSH key at `/run/secrets/…` only; **wrappers** inject it (not copied into hermes HOME). See `hosts/system/hermes/modules/workstation.nix`.
- Workstation hop: skill **`workstation`**, commands `checkout-workstation` / `release-workstation` / `ssh-workstation`; no Wake-on-LAN.

### Service Architecture

Philosophy: **Docker for complex/dependency-heavy stacks, native NixOS for simple/well-supported services.**

| Service | Type | Module | Notes |
|---------|------|--------|-------|
| Docker engine | Native | `containers.nix` | Auto-prune, unified refresh timer |
| Home Assistant + Matter + OTBR | Docker | `containers/home-assistant.nix` | Host network for mDNS/Thread |
| Files (NFS+SMB) | Native | `services/filesharing.nix` | Guest-only drop zone `/media/Files/Share` |
| Hermes Agent + GBrain | NixOS module + container | `hermes/hermes.nix` (hermes-pnp) + `hermes/modules/` | xAI OAuth / Grok, low/medium/high router, GBrain MCP + reflex, WebUI; SOUL not declarative |
| Tailscale VPN | Native | `services/tailscale.nix` | |
| AdGuard Home DNS | Native | `services/adguard.nix` | Port 53 + web UI 3000 |
| Caddy | Native | `services/caddy.nix` | Reverse proxy, Cloudflare ACME |
| CrowdSec | Docker+Native | `containers/crowdsec.nix` | Engine in container, nftables bouncer native |
| Remote Desktop | Native | `services/remote-desktop.nix` | XFCE + xrdp |

Disabled but available: Cockpit, Cloudflared, arr-suite, Transmission.

**containers.nix** is pure infrastructure — Docker engine, auto-prune, unified `refresh-containers` timer. Container definitions live in their respective modules. `containerNames` and `uniqueImages` are auto-discovered from all imported modules. The single `refresh-containers` timer (Sun 02:00) pulls all images and restarts all containers.

### Docker Network Patterns

- **Host network** (`--network=host`): Used by HA, Matter, OTBR, Hermes container (for local tools, OAuth callbacks, etc.)
- **Bridge network**: Available for any sandboxed workloads the agent spawns via terminal/docker (Hermes itself does not use the old multi-agent bridge pattern)

### Env Injection Pattern

Docker containers needing sops secrets use a separate oneshot service (runs before container) to:
1. Read secrets from sops paths (`cat ${config.sops.secrets.*.path}`)
2. Write env files to `/run/<name>.env` (mode 600/640)
3. Container references via `environmentFiles = [ "/run/<name>.env" ]`

Examples: `hermes-agent-setup` (via the official module) + our activation writes `/run/hermes.env`, `caddy-env` writes `/run/caddy.env`.

### Hermes Agent Architecture

Hermes Agent (from `github:NousResearch/hermes-agent`) is composed by flake input `hermes-pnp` in `hosts/system/hermes/hermes.nix`. Host leftovers (GBrain Bearer rewrite, Composio policy, OneDrive, workstation) stay under `hosts/system/hermes/modules/`.

- **Deployment mode**: `container.enable = true` (Ubuntu 24.04, module `--network=host`). State under `/var/lib/hermes`.
- **Model**: `settings.model.provider = "xai-oauth"`, `default = "grok-4.6"`. One-time `hermes auth add xai-oauth` after deploy (see `hosts/system/hermes/BOOTSTRAP.md`).
- **Identity**: **No declarative SOUL.md** — activation does not install persona docs. Agent owns identity.
- **GBrain**: `hermesPnP.gbrain.enable` starts loopback `gbrain serve`; host `modules/gbrain.nix` is leftovers (Bearer rewrite, git-credential, 1G cap). **No** host exclusive consolidate/dream/embed timers. Agent never shells `gbrain`. CLI install is bun-global (bootstrap only), not a Nix package.
- **Secrets**: sops `hermesEnv` → `/run/hermes.env`, including `ZEROENTROPY_API_KEY` for embeddings. Encrypt/decrypt via `secrets/encrypt` + `secrets/decrypt`.
- **CLI routing**: `addToSystemPackages = true`; host `hermes` routes into the container.
- **Caddy**: WebUI on 8787 → `archimedes.${domain}` (LAN) + Cloudflare Tunnel (WAN). Official `hermes dashboard` / `hermes.${domain}:9119` is decommissioned.
- **Bootstrap / ops docs**: `hosts/system/hermes/BOOTSTRAP.md` + `hosts/system/hermes/AGENTS.md`.
- **Deploy helpers**: `./deploy validate-gbrain` / `gbrain-setup` (scripts from locked hermes-pnp), `./deploy clean-hermes-state`.
- **Memory / OOM (8 GiB board):** Hermes is tertiary vs AdGuard + HA. Gateway + WebUI agent processes **2 GiB** / 2 CPU / OOM +500 (`runtime.nix`); browser **1 GiB**; host **8 GiB** swapfile on root SSD (`partitions.nix`). Full table: `hosts/system/hermes/AGENTS.md` § Resource limits / OOM policy. Heavy nix eval/build → workstation, not on-box Hermes.


### Caddy Reverse Proxy (LAN)

Admin API is off (`admin off`, `enableReload = false`). Config is the Caddyfile only — host-net jails share loopback, so `:2019` is not a boundary.

Custom option `services.caddy.proxyServices` maps hostnames → backend ports. Each entry gets HTTPS (Cloudflare DNS-01) and reverse_proxy to localhost. Non-`externalHosts` clients outside LAN get 403.

```nix
services.caddy.proxyServices."files.${settings.domain}" = 8080;  # LAN
services.caddy.externalHosts = [ "homeassistant.${settings.domain}" ];  # optional: no LAN guard
```

### Cloudflare Tunnel (public / CGNAT)

Starlink CGNAT: inbound 443 and orange-cloud→origin both fail. Public HTTPS uses an **outbound** tunnel.

```nix
# Same shape as caddy.proxyServices — declare in the service module:
services.cloudflareTunnel.proxyServices."archimedes.${settings.domain}" = 8787;
services.cloudflareTunnel.proxyServices."homeassistant.${settings.domain}" = 8123;
```

- **Enable:** `settings.cloudflareTunnelId` + sops `cloudflared_tunnel_credentials` (once via `./scripts/setup-cloudflare-tunnel.sh`)
- **DNS:** setup script creates proxied CNAME → `<tunnelId>.cfargotunnel.com` for each proxyServices hostname
- **Path:** browser → CF edge → cloudflared → `127.0.0.1:<port>` (skips Caddy)
- Module: `hosts/system/services/cloudflared.nix`

### ZFS Pool

Single pool mounted at `/media` with `nofail` + `zfsutil` (boot succeeds even if pool doesn't exist):

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

**Remote interaction policy:** agents **must** prefer `./deploy` for all server work (discovery, SSH options, command wrapping). Direct `ssh` only when `./deploy` cannot express the action. Drive rebuilds, log inspection, Hermes chat/doctor, and `./deploy validate-gbrain` **autonomously** until the goal succeeds or a true user-only blocker remains. Server is ARM64 with limited resources — prefer workstation `remote-*` builds. Cap log pulls (`--tail 100` / `-n 100`).

### Installation Flow

Fully remote from workstation — two boot options:
1. **USB ISO**: `./deploy build-iso` — builds pure ISO, offers to write to USB
2. **PXE netboot**: `./deploy build-netboot` then `./deploy netboot` — starts PXE server with LAN proxy or direct-connect mode

Then:
3. `./deploy install` — SSH in, partition (GPT: 512M EFI + ext4 root), rsync repo + SOPS key, nixos-install from local flake
4. Reboot — device is fully operational, sops-nix decrypts secrets on first boot
5. Subsequent updates: `./deploy remote-switch` or on-device `switch`

### PXE Netboot

Boot chain: dnsmasq(DHCP+TFTP) -> snp.efi(iPXE) -> HTTP(kernel+initrd)

Two network modes:
- **LAN proxy** — workstation and device on the same router. dnsmasq acts as DHCP proxy.
- **Direct connect** — ethernet cable between workstation and device. Full DHCP server on 192.168.100.0/24.

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
- `upgrade` / `remote-upgrade` — same + update nixpkgs/flake inputs + refresh container images

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
1. Create a new module in `hosts/system/containers/`
2. Define containers under `virtualisation.oci-containers.containers`
3. Add firewall ports in the same module
4. Add import to `containers.nix`
5. Container exec wrapper and refresh timer auto-include (no manual step)

### Adding Native Services
1. Create a new module in `hosts/system/services/`
2. Use the NixOS module system (`services.<name>.enable = true`)
3. Reference sops secrets via `config.sops.secrets.*`
4. Add import line to `services.nix`

## Gotchas

- **Always `git add` changed files before any `nix build`, `nixos-rebuild`, or `./deploy` that uses the flake**. Flakes only see the git index — unstaged edits are invisible and cause "no such option" or stale builds.
- **Tarball cache corruption** during long cross-builds shows as the build process stuck in `unix_stream_read_generic` (check `cat /proc/<pid>/wchan`). Fix: `rm -rf ~/.cache/nix/tarball-cache` (then retry). Do not recreate the dir manually.
- ISO/netboot build requires aarch64 support (binfmt/qemu or remote builder) since target is aarch64
- `adminUser` cannot move to SOPS (needed at Nix eval time for attribute name)
- Static IP is used (no NetworkManager) — `useDHCP = false` in system config, `useDHCP = true` in installer
- Services toggled in `hosts/system/services.nix` by uncommenting imports
- Kernel 6.18 is required for rk3588 — builds are slow due to cross-compilation
- sops-nix warnings during `nixos-install` are normal — secrets materialize on first real boot
- ZFS dataset mounts use `nofail` — boot succeeds even if pool isn't created yet
- `services.resolved.enable = false` in adguard.nix — systemd-resolved conflicts with port 53
- Cloudflare Tunnel uses DynamicUser + LoadCredential; sops secret is root-owned. Set `settings.cloudflareTunnelId` and declare `services.cloudflareTunnel.proxyServices` per app
- Docker containers with static tags (`:latest`, `:stable`) are NOT re-pulled on rebuild — the unified `refresh-containers` timer (Sun 02:00) and per-service refresh timers handle image updates
- Hermes container uses host network + bind mounts; agent tools inside see the hermes user env and writable layer. No more `ws://172.17.0.1` gateway for sub-agents (single-agent model).
- Hermes workspace (`/var/lib/hermes/workspace`) is owned by the hermes system user; OneDrive sync and hostUsers (in hermes group) have group-writable access.
- Persistent settings go in `/var/lib` — both for native services and Docker container volume mounts
- **No Nix one-shots for leftover state.** Do not add activation `rm -f`, `mkForce false` tombstones, or oneshot units to mop up a rename or retired file. `./deploy` SSH and do the operation once. Nix only declares the desired ongoing system.

### Network / Router Notes
- When enabling IP forwarding (`net.ipv6.conf.all.forwarding = 1` or equivalent), the kernel resets `accept_ra = 0` on interfaces. Set `accept_ra = 2` (or the desired value) **after** forwarding via a dedicated systemd service that runs after `systemd-sysctl.service`. See `ipv6-accept-ra` pattern if re-implementing.


**Please consider leaving a star if this repo saved you time or tokens :)**
