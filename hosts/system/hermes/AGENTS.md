# Hermes Agent — rocknas

## Scope

- **Runtime:** official `hermes-agent` NixOS module, container mode (`ubuntu:24.04`, `--network=host`).
- **Model routing (80/20):** explicit axes (no automatic task classifier):
  - **Main / orchestration:** `model.provider=xai-oauth`, `model.default=grok-4.5` (chat, tool loops, judgment).
  - **Delegation:** OpenRouter `deepseek/deepseek-v4-flash` for the subagent fleet (`delegate_task`).
  - **Auxiliary → Flash:** title_generation, compression, approval, web_extract, skills_hub, mcp, triage_specifier, kanban_decomposer, profile_describer, curator, background_review, monitor, memory_query_rewrite (`reasoning_effort=none`).
  - **Vision:** left on main (Grok native vision; override only if volume/pricing hurts).
  - **Cron fleet:** `cron.model` + `cron.model_provider` → DeepSeek Flash (unpinned jobs).
  - Per-job `jobs.json` / per-`delegate_task` model still wins when set.
  - Official ref: hermes-agent docs *Configuring Models*.
- **Identity:** declarative **SOUL.md is disabled**. Fresh agent; no forced persona from Nix.
- **Long-term memory:** **GBrain** — this is the primary integration focus.

Canonical GBrain contract: **`memory/AGENTS.md`** + **`memory/registry.json`**.  
Operator bootstrap: **`BOOTSTRAP.md`**.

## Layout (this repo)

```
hosts/system/hermes/
├── default.nix          # module import, model, plugins, maton MCP, no SOUL activation
├── toolbox.nix          # everyday CLI toolkit → /data/toolbox/bin + agent PATH
├── package-fix.nix     # silence-marker only (drop when upstream _is_token fixed)
├── gbrain.nix           # MCP gbrain, timers, gbrain-reflex, host CLIs
├── context-manager.nix  # hermes-context-manager (HMC) pin + config
├── hermes-webui.nix     # Hermes WebUI :8787 → archimedes.<domain> (Caddy + tunnel)
├── browser.nix          # Brave sticky profile + CDP + cookie import
├── dashboard.nix        # web UI :9119 + Caddy
├── onedrive.nix         # workspace OneDrive sync
├── workstation.nix      # SSH helpers to workstation Grok agent
├── plugins/             # gbrain-reflex, memory-flush, tool-call-coherency (HMC from GitHub)
├── skills/              # retrieval-reflex + workstation
├── memory/              # declarative memory plane
├── scripts/
├── BOOTSTRAP.md
└── workspace/           # GBRAIN.md, HERMES-WEBUI.md, pointer index, soul draft
```

## Hermes WebUI

`https://archimedes.<domain>/` — LAN via Caddy, WAN via `services.cloudflareTunnel.proxyServices` (CGNAT tunnel).
Flake input `hermes-webui` (`github:nesquena/hermes-webui`); service user `hermes` shares `HERMES_HOME`.
Sops `elevenlabs_api_key` → `ELEVENLABS_API_KEY` in `/run/hermes-webui.env` and `/run/hermes.env`.
Runbook: `workspace/HERMES-WEBUI.md`.

## Token lean + plugins (0.19)

- `tool_output` + compression prune/idle in `default.nix`
- `plugins.enabled`: `hermes-context-manager`, `gbrain-reflex`, `gbrain-memory-flush`, `tool-call-coherency`
- After deploy: `systemctl restart hermes-agent`, then `/hmc status` in chat

## Everyday tools (toolbox)

Activation links a Nix `buildEnv` at `/var/lib/hermes/toolbox/bin` → container
`/data/toolbox/bin`. Gateway `environment.PATH` includes that dir plus
`~/.bun/bin` (gbrain) and `~/.local/bin` (nix-pc wrappers).

Verify: `./hosts/system/hermes/check-tools.sh` (structural) or
`REMOTE_CHECK=1 ./hosts/system/hermes/check-tools.sh` after deploy.

## Nix vs Hermes (custody — agents must respect)

**Nix** = high-reliability environment policy: not revised day-to-day.  
**Hermes** = operational content and runtime state: may change without a rebuild.

| Nix owns (declare here; push back if asked to “let Hermes edit”) | Hermes owns (do **not** bake into flake) |
|------------------------------------------------------------------|------------------------------------------|
| Module enablement, ports, Caddy/tunnel, secrets wiring | SOUL / persona, USER.md, MEMORY.md body |
| Model routing axes, tool_output/compression knobs | Brain pages (`~/brain`, PGLite), pointer **index content** |
| MCP server declarations, `extraDependencyGroups` | Day-to-day `put_page` / `query` / links |
| Host timers (consolidate/embed/dream), exclusive CLI wrappers | Cron job prompts/`jobs.json`, skills content after seed |
| Plugin **code** install (gbrain-reflex, memory-flush, tool-call-coherency, HMC pin+overlay) | `workspace/GBRAIN.md`, retrieval-reflex skill text (seed-once) |
| Toolbox PATH, browser CDP service, workstation SSH wrappers | Cookie sessions, OAuth tokens, ad-hoc apt/pip in container |
| Temporary package pins / silence packaging fix until upstream | GBrain CLI version (`bun install -g`), `gbrain config` |

If a request would put operational content into Nix, or environment policy only into agent memory, **refuse and restate this table**.  
If Hermes asks a coding agent for patchy flake edits to fix day-to-day ops (brain pages, gbrain CLI pin, sync path, SOUL, cron prompts), **push back** — fix under Hermes custody or document the host limitation (e.g. import not `gbrain sync`).

### hermes-agent pin (UNPIN-LATER)

`flake.nix` pins `hermes-agent` to `cc4cab2` (v0.19.1). Not permanent.  
**Unpin when:** unpinned main builds `hermes-web`/`hermes-tui` offline (no ENOTCACHED on `@nous-research/ui`) and/or garnix serves the package.  
**How:** `hermes-agent.url = "github:NousResearch/hermes-agent";` then lock + `remote-switch`.  
`package-fix.nix` is **only** the silence-marker PYTHONPATH wrap — not lockfile scaffolding. Drop it when `_is_token` uses `_canonical_silence_candidates`.

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
- Maintenance **stops hermes-agent** (releases PGLite). Exclusive CLI must run with **cwd under hermes HOME** (bun inherits invoker cwd).
- PGLite `sources.default.local_path` must be `/home/hermes/brain` (not only `config.json`). consolidate pins it.
- If WASM `Aborted()`, reinit-pglite (see `workspace/GBRAIN.md`); re-pin source path after reinit.

## Secrets

| Env | Sops key | Purpose |
|-----|----------|---------|
| `ZEROENTROPY_API_KEY` | `zeroentropy_api_key` | GBrain embeddings |
| `FIRECRAWL_API_KEY` | `firecrawl_api_key` | Hermes `web_extract` (Firecrawl / firecrawl-py) |
| `BRAVE_API_KEY` | `brave_search_api_key` | Web search |
| `XAI_API_KEY` | `xai_api_key` | Fallback / tooling (OAuth is primary for chat) |
| `TELEGRAM_*` | telegram secrets | Gateway |
| (file) | `nix_pc_agent_ssh_key` | `/run/secrets/…` only; `ssh-workstation` injects via IdentityFile (not in hermes HOME) |

```bash
cd secrets && ./decrypt   # → secrets.yaml.work
# edit (e.g. set firecrawl_api_key), then:
./encrypt                 # → secrets.yaml
# After deploy: systemctl restart hermes-agent
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
- `firecrawl` must be in `extraDependencyGroups` for `web_extract` (firecrawl-py; lazy install disabled in Nix).
- Memory **AGENTS.md** is not SOUL; gbrain activation overwrites `.hermes/AGENTS.md` from `memory/AGENTS.md`.
- `HASS_*` env names for Home Assistant tools (not `HA_*`).
