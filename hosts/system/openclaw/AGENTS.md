# OpenClaw Module - Agent Guide

Module-specific context for the `hosts/system/openclaw/` subtree. Read alongside the repo-level `AGENTS.md`.

## Module Layout

```
openclaw/
├── default.nix        # Module entry point (imports components)
├── agents.nix         # Agent definitions & JSON config logic
├── config.nix         # Gateway config generation
├── workspace/         # Workspace document templates (protected vs persistent sections)
│   ├── default.nix    # Assembly entry point (documents + tasks map)
│   ├── soul.nix       # SOUL.md template (personality, voice, continuity)
│   ├── agents.nix     # AGENTS.md template (server rules, tooling, automation)
│   ├── style.nix      # STYLE.md template (formatting, language policy)
│   └── tasks.nix      # Lobster workflow starter templates (.lobster YAML)
├── image.nix          # Custom Docker image builder service
├── deployment.nix     # Setup service (deploy) & refresh timer
└── onedrive.nix       # Bidirectional rclone sync
```

## Path Mapping

| Host path | Container path | Notes |
|---|---|---|
| `/var/lib/openclaw` | `/home/node/.openclaw` | Single volume mount, rw |
| `.../openclaw.json` | `.../openclaw.json` | Generated config (from Nix) |
| `.../workspace` | `.../workspace` | Main agent workspace |
| `.../workspace/tasks` | `.../workspace/tasks` | Lobster workflow files (.lobster) |
| `.../workspace/sub-agents/*` | same | Sub-agent workspaces |
| `/run/openclaw.env` | N/A | Secrets for env interpolation |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Sandbox spawning |

Gateway env vars (`OPENCLAW_HOME`, `OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`) explicitly point to container paths. Subagent sandboxes get these via `agents.defaults.sandbox.docker.env` in `openclaw.json`.

## Container Architecture

- **openclaw-builder** (oneshot, `image.nix`) - builds `openclaw-custom:latest` from upstream base image, adds Docker CLI + uv. Runs before gateway.
- **openclaw-gateway** - main process, user `1000:1000`, `--network=host`, docker group for socket access.
- **openclaw-cli** - ephemeral `docker run` via the `oc` wrapper. Same image, same user, same mounts.

All containers run as UID 1000 (maps to `node` inside, `user` on host). No root at runtime.

## Workspace & Config Deployment

Managed via `deployment.nix`. On rebuild/restart:
1. **Config**: Generated `openclaw.json` (from `config.nix` + `agents.nix`) overwrites `/var/lib/openclaw/openclaw.json`.
2. **Workspace**:
   - `AGENTS.md`, `SOUL.md`, `STYLE.md` (main agent) and `AGENTS.md` (sub-agents) are generated from templates.
   - **Persistence Pattern**: Documents use a "Protected" top section (repo-managed) and a "Persistent" bottom section (agent-managed) marked by `<!-- OPENCLAW-PERSISTENT-SECTION -->`.
   - **Main Agent**: Uses `workspace/` for its core files (`soul.nix`, `agents.nix`, `style.nix`). `AGENTS.md` dynamically lists available secrets from `sops.nix` and `api-gateway` services.
   - **Sub-agents**: Identity files (`SOUL.md`, `USER.md`) and workflows are pulled from `openclaw-agents` input. `AGENTS.md` is managed via `subAgentWorkspace` in `agents.nix` to allow sub-agent persistence. `STYLE.md` is shared from main.
   - **Lobster tasks**: `workspace/default.nix` generates `.lobster` YAML workflow files into `workspace/tasks/`. Starters: `inbox-triage` (approval-gated pipeline) and `jacket-advice` (conditional LLM). Run via `lobster run tasks/<name>.lobster`.

## Agent Sandbox Defaults & Key Splitting

Sandbox defaults in `openclaw.json` apply to ALL sandboxed agents unless overridden per-agent:
- Security baseline: `capDrop: ["ALL"]`, `user: "1000:1000"`, 1 cpu
- Network: bridge (connects to gateway via ws://172.17.0.1:18789)
- `readOnlyRoot: true`

**Per-agent tool restrictions are currently disabled** while sandbox tool provisioning is being debugged. See `agents.nix` for the commented-out `tools` block in `mkAgent`.

Target architecture: per-agent allowlists built from `defaultTools ++ extraAllow` in `agents.nix`.

## Editing openclaw.json

Generated from Nix. To edit:
1. Modify `config.nix` (gateway settings) or `agents.nix` (agent definitions).
2. Rebuild and deploy (`deploy remote-switch`).
3. `/var/lib/openclaw/openclaw.json` is overwritten.

Secrets use `${ENV_VAR}` syntax - resolved by the gateway from env vars injected via `sops-nix` -> `/run/openclaw.env`.

## OneDrive Sync

- Runs as UID 1000, group `users`
- Copies sops rclone config to writable temp file before running
- Bidirectional: pulls remote -> local, then pushes local -> remote
- Syncs `Shared` and `Documents` folders into `workspace/onedrive/`
- 15m timer with 2m jitter, 5m delay after boot

## Testing Sub-Agent Tools

After deploying config changes, verify sub-agent tool availability:

```bash
# Deploy config
deploy remote-switch

# SSH into device
deploy ssh

# Spawn a test sub-agent and ask it to list tools
oc sessions spawn --agent scout --task "List every tool you have access to. Output tool names only, one per line."

# Check sandbox state
oc sandbox explain

# Query docs inside the container
docker exec openclaw-gateway openclaw docs tools.sandbox.tools
docker exec openclaw-gateway openclaw docs tools.subagents
```

### Tool Permission Layers (all must permit a tool)

1. `tools.profile` — base tool set
2. `tools.allow/deny` — global filter
3. `agents.list[].tools.allow/deny` — per-agent filter
4. `tools.subagents.tools` — sub-agent filter (default: all except session tools)
5. `tools.sandbox.tools` — sandbox filter (default: exec, browser, process only)

Layer 5 (`tools.sandbox.tools`) requires **explicit group names** — wildcard `"*"` does not work.

## Upgrade & Container Refresh

`openclaw-refresh` timer (Mon 04:00) pulls the base image, rebuilds custom, and restarts the gateway. `refresh-containers.service` runs after system activation on upgrade.
