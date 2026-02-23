# OpenClaw Module — Agent Guide

Module-specific context for the `hosts/system/openclaw/` subtree. Read alongside the repo-level `AGENTS.md`.

## Module Layout

```
openclaw/
├── default.nix        # Gateway + CLI containers, builder, preStart, refresh timer
├── openclaw.json      # Committed gateway config (merged into runtime on each start)
├── onedrive.nix       # Bidirectional rclone sync (15m timer, UID 1000, group "users")
└── workspace/         # Nix-managed dotfiles → /var/lib/openclaw/workspace/
    ├── AGENTS.md      # Multi-agent role rules (deployed to workspace, not this file)
    ├── SOUL.md        # Personality directives
    └── STYLE.md       # Message formatting rules
```

## Path Mapping

| Host path | Container path | Notes |
|---|---|---|
| `/var/lib/openclaw` | `/home/node/.openclaw` | Single volume mount, rw for gateway |
| `/var/lib/openclaw/openclaw.json` | `/home/node/.openclaw/openclaw.json` | Config file |
| `/var/lib/openclaw/workspace` | `/home/node/.openclaw/workspace` | Agent workspace |
| `/var/run/docker.sock` | `/var/run/docker.sock` | For sandbox spawning |

Gateway env vars (`OPENCLAW_HOME`, `OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`) explicitly point to container paths. Subagent sandboxes get these via `agents.defaults.sandbox.docker.env` in `openclaw.json`.

## Container Architecture

- **openclaw-builder** (oneshot) — builds `openclaw-custom:latest` from upstream base image, adds Docker CLI + uv. Runs before gateway via `requiredBy`.
- **openclaw-gateway** — main process, user `1000:1000`, `--network=host`, docker group for socket access.
- **openclaw-cli** — ephemeral `docker run` via the `oc` wrapper in `scripts.nix`. Same image, same user, same mounts.

All containers run as UID 1000 (maps to `node` inside, `user` on host). No root anywhere at runtime.

## Config Merge Strategy

`preStart` runs `jq -s '.[0] * .[1]'` — shallow merge of runtime config with committed `openclaw.json`. Nix-declared values always win for top-level keys, but nested runtime additions (e.g., new agents added via UI) are preserved.

## Agent Sandbox Defaults & Key Splitting

Sandbox defaults in `openclaw.json` apply to ALL sandboxed agents unless overridden per-agent. The defaults provide:
- Config dir bind mount (ro) so sandboxes can resolve browser profiles and gateway config
- Base env vars (`HOME`, `OPENCLAW_*`) for path resolution
- Security baseline: `capDrop: ["ALL"]`, `user: "1000:1000"`, 1g memory, 1 cpu

**Per-agent tool & key profiles:**

| Agent | Tools (allow) | Keys | Deny |
|---|---|---|---|
| main | `group:sessions`, `memory`, `config` | All (gateway env) | web, browser, email, fs, exec |
| researcher | `group:web`, `browser`, `read`, `exec` | BRAVE, BROWSERLESS, GOOGLE_PLACES | email, write |
| communicator | `group:email`, `write` | MATON, TELEGRAM | web, browser, exec |
| controller | `group:ha`, `mcp` | HA_URL, HA_TOKEN | web, browser, email, exec |

This is the two-key vault principle: main holds all keys but never touches the network directly. Specialists get only what they need. Prompt injection in one sandbox can't reach another's credentials.

## Editing openclaw.json

The JSON config is committed and merged on every gateway start. When editing:
- Top-level keys from the committed file always overwrite runtime values
- Nested objects are shallow-merged (runtime additions preserved)
- Secrets use `${ENV_VAR}` syntax — the gateway interpolates from its environment
- Per-agent `docker.env` entries use the same `${VAR}` syntax, resolved from the gateway process env

After editing, rebuild and deploy — the preStart merge handles the rest. No need to manually restart or edit on the device.

## OneDrive Sync

- Runs as UID 1000, group `users` (not a GID 1000 group — that doesn't exist on host)
- Copies sops rclone config to writable temp file before running (sops path is read-only)
- Bidirectional: pulls remote → local, then pushes local → remote
- Syncs `Shared` and `Documents` folders into `workspace/onedrive/`
- 15m timer with 2m jitter, 5m delay after boot

## Upgrade & Container Refresh

`upgrade` and `remote-upgrade` trigger `refresh-containers.service` after system activation. This pulls latest images for all containers and restarts any that changed. The `openclaw-refresh` timer (Mon 04:00) independently pulls the base image, rebuilds custom, and restarts the gateway.
