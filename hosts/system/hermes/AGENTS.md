# Hermes Agent — rocknas

## Scope

- **Runtime:** official `hermes-agent` NixOS module, container mode (`ubuntu:24.04`, `--network=host`).
- **Model routing:** explicit config axes (no automatic task classifier):
  - **Main / orchestration:** `model.provider=xai-oauth`, `model.default=grok-4.5` (Telegram chat, interactive).
  - **Delegation:** `delegation` → OpenRouter `deepseek/deepseek-v4-flash` (child agents only).
  - **Auxiliary:** compression, titles, approvals, monitor, background_review, … → DeepSeek Flash.
  - **Cron fleet:** `cron.model` + `cron.model_provider` → DeepSeek Flash (unpinned jobs; beats chat model).
  - Per-job `jobs.json` `model`/`provider` still wins for a single schedule.
- **Identity:** declarative **SOUL.md is disabled**. Fresh agent; no forced persona from Nix.
- **Long-term memory:** **GBrain** — this is the primary integration focus.

Canonical GBrain contract: **`memory/AGENTS.md`** + **`memory/registry.json`**.  
Operator bootstrap: **`BOOTSTRAP.md`**.

## Layout (this repo)

```
hosts/system/hermes/
├── default.nix          # module import, model, maton MCP, no SOUL activation
├── toolbox.nix          # everyday CLI toolkit → /data/toolbox/bin + agent PATH
├── gbrain.nix           # MCP gbrain, timers, activation, host CLIs
├── dashboard.nix        # web UI :9119 + Caddy
├── onedrive.nix         # workspace OneDrive sync
├── workstation.nix      # SSH helpers to workstation Grok agent
├── memory/              # declarative memory plane (→ /var/lib/hermes/memory + live AGENTS.md)
├── prompts/
├── scripts/             # consolidate/embed/validate/clean-hermes-state + check-tools
├── BOOTSTRAP.md
└── workspace/soul.md    # DRAFT ONLY — not installed
```

## Everyday tools (toolbox)

Activation links a Nix `buildEnv` at `/var/lib/hermes/toolbox/bin` → container
`/data/toolbox/bin`. Gateway `environment.PATH` includes that dir plus
`~/.bun/bin` (gbrain) and `~/.local/bin` (nix-pc wrappers).

Verify: `./hosts/system/hermes/check-tools.sh` (structural) or
`REMOTE_CHECK=1 ./hosts/system/hermes/check-tools.sh` after deploy.


## GBrain (summary)

```
Telegram / hermes chat / dashboard
        │
        ▼
hermes-agent (docker) ── MCP stdio ──► gbrain serve  (bun global in container)
        │                                  │
        │ Hermes MEMORY.md / USER.md       ├── ~/brain (git)
        │ export/inbox + snapshots         └── ~/.gbrain/brain.pglite
        ▼
hermes-gbrain-consolidate (daily) → gbrain put + dream
gbrain-embed (Sun 05:00)          → gbrain embed --stale
gbrain-dream (04:30)              → gbrain dream
```

- CLI expected at `~/.bun/bin/gbrain` (host: `/var/lib/hermes/home/.bun/…`).
- Embeddings: `ZEROENTROPY_API_KEY` via sops → `/run/hermes.env`.
- Maintenance pauses `gbrain serve` (PGLite lock).

## Secrets

| Env | Sops key | Purpose |
|-----|----------|---------|
| `ZEROENTROPY_API_KEY` | `zeroentropy_api_key` | GBrain embeddings |
| `XAI_API_KEY` | `xai_api_key` | Fallback / tooling (OAuth is primary for chat) |
| `TELEGRAM_*` | telegram secrets | Gateway |
| (file) | `nix_pc_agent_ssh_key` | `/run/secrets/…` only; `ssh-workstation` injects via IdentityFile (not in hermes HOME) |

```bash
cd secrets && ./decrypt   # → secrets.yaml.work
# edit, then:
./encrypt                 # → secrets.yaml
```

## Coding workstation

Module: `workstation.nix` — PATH helpers + skill **`workstation`**
(`skills/workstation/SKILL.md` → `~/.hermes/skills/devops/workstation/`).

**Not MCP tools.** Discovery: `/workstation`, skill index, NL; run via **`terminal`**.

Host powered on. Checkout latch until release. Key never placed in hermes HOME.

```bash
checkout-workstation
ssh-workstation true
ssh-workstation 'bash -lc "grok --always-approve -p …"'
release-workstation
```

## Communicate with the agent

**Agents should run these via `./deploy` themselves** — do not wait for the human to poke Hermes or validate GBrain when the goal requires it.

| Method | Command / URL |
|--------|----------------|
| CLI | `./deploy hermes chat` / `./deploy hermes doctor` / `./deploy hermes mcp list` |
| GBrain ops | `./deploy validate-gbrain`, `./deploy gbrain-consolidate` |
| SSH | `./deploy ssh` (fallback; prefer named `./deploy` subcommands) |
| Telegram | bot DM (allowlisted) |
| Dashboard | `https://hermes.<domain>/` |
| Logs | `./deploy journal hermes-agent` / `./deploy logs hermes-agent` |

Bootstrap prompts and gbrain install instructions: **`BOOTSTRAP.md`**. After `remote-switch`/`remote-upgrade`, continue autonomously: confirm OAuth, prompt/install GBrain, run validate + benchmark prompts.

## Host maintenance commands

```bash
systemctl status hermes-agent
hermes-gbrain-consolidate          # after remote-switch
hermes-gbrain-embed
systemctl list-timers | grep gbrain
# Soft reset agent state, keep gbrain install + brain:
sudo bash hosts/system/hermes/scripts/clean-hermes-state.sh
```

## Lessons (short)

- Module container is always `--network=host` — no docker `-p` for dashboard.
- `messaging` must be in `extraDependencyGroups` (not in hermes `[all]`).
- Memory **AGENTS.md** is not SOUL; gbrain activation overwrites `.hermes/AGENTS.md` from `memory/AGENTS.md`.
- `HASS_*` env names for Home Assistant tools (not `HA_*`).
