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
- **openclaw** (host CLI) - `docker exec` into running gateway via the `openclaw` wrapper script. No separate container.

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

**Tool policy is deny-based** — `profile = "full"` gives all tools, `tools.deny` removes what's not needed.

Three tiers defined in `agents.nix`:
- **Common:** every sub-agent gets these (read, write, edit, web_search, web_fetch, browser, image, memory tools, session coordination, tts, pdf)
- **Privileged:** denied by default, granted per-agent via `grantPrivileged` (exec, apply_patch, process, sessions_spawn, subagents)
- **Admin:** denied from all sub-agents (cron, gateway, nodes, message, canvas)

To add a new tool grant: edit `agentOverrides.<id>.grantPrivileged` in `agents.nix`. SOUL.md table and per-agent AGENTS.md update automatically on deploy.

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
deploy remote-switch
deploy ssh

# ── Agent commands (fall back to embedded mode — see caveat below) ──
openclaw agent --agent scout --message "return only the output of available_tools"
openclaw agent --agent <id> --message "<instruction>"

# ── Config & diagnostics (these work correctly via docker exec) ──
openclaw doctor
openclaw agents list --bindings
openclaw sandbox explain --agent scout
openclaw plugins list
openclaw config get tools --json
openclaw docs tools.sandbox.tools

# ── JSON deny list sanity check (mirrors Nix, useful to spot typos) ──
cat /var/lib/openclaw/openclaw.json | grep -oP '"id":"[^"]+"|"deny":\[[^\]]+\]'
```

**Agent command caveat:** `openclaw agent` runs via `docker exec -u node` inside the gateway container, reusing the gateway's paired device identity. However, the CLI-to-gateway websocket handshake consistently times out (upstream issue — the CLI `agent` command doesn't complete the handshake within the gateway's timeout window), causing fallback to **embedded mode** (unfiltered tool set).

**To validate tool filtering with all 8 layers applied**, prompt a sub-agent through Telegram or the Control UI — these are already-connected channels that go through the full gateway pipeline.

### Tool Permission Hierarchy

OpenClaw filters the master tool list **top-to-bottom** before dispersing the final set to the agent/model. Each layer **only restricts further**; no layer can re-grant a tool denied earlier. `deny` **always wins** over `allow`/`profile` at every step.

Exact evaluation pipeline (verbatim from docs):

1. **`tools.profile`** (or `agents.list[].tools.profile`) — base allowlist preset (`minimal` / `coding` / `messaging` / `full`).
2. **`tools.byProvider[provider].profile`** (or per-agent) — provider/model-specific preset.
3. **`tools.allow`** + **`tools.deny`** — global policy (deny wins).
4. **`tools.byProvider[provider].allow/deny`** — provider/model override.
5. **`agents.list[].tools.allow/deny`** — per-agent policy.
6. **`agents.list[].tools.byProvider[provider].allow/deny`** — per-agent + provider.
7. **Sandbox policy** (`tools.sandbox.tools` or `agents.list[].tools.sandbox.tools`) — only for sandboxed sessions.
8. **Subagent policy** (`tools.subagents.tools.allow/deny`) — if spawning children.

**Final remaining tools** are the ones the agent actually sees and can call. Anything dropped never reaches the model.

Runtime execution guards (file path rules, exec approvals, elevated `allowFrom`, sandbox container) kick in **after** this filter — they do not change what the model is offered.

**Note:** Layer 7 (`tools.sandbox.tools`) requires explicit group names — wildcard `"*"` does not work. Use `group:fs`, `group:runtime`, `group:sessions`, `group:web`, `group:memory`, `group:ui`, `group:openclaw`, etc.

## Upgrade & Container Refresh

`openclaw-refresh` timer (Mon 04:00) pulls the base image, rebuilds custom, and restarts the gateway. `refresh-containers.service` runs after system activation on upgrade.
