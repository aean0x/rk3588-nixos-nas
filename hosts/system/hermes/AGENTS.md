# Hermes Agent — rocknas

## Scope

- **Runtime:** official `hermes-agent` NixOS module, container mode (`ubuntu:24.04`, `--network=host`).
- **Model routing:** plugin `model-router` classifies each main-agent turn (native providers, not OpenRouter):
  - **T1** `deepseek` / `deepseek-v4-flash` — acks, trivias, docs/drafting (old T1+T2).
  - **T2** `deepseek` / `deepseek-v4-pro` — debug, review, complex analysis, optimization, nuanced review (old T3+T4 + low-signal T4).
  - **T3** `xai-oauth` / `grok-4.6` — architecture, security, high-stakes, migration, tool-error escalate, end-of-turn final-voice polish.
  - Pins: `/t1` `/t2` `/t3` `/auto` via `ctx.register_command` (CLI + gateway).
  - Classifier uses existing `auxiliary.triage_specifier` (Flash). No SOUL.md writes.
  - Cron + `delegate_task` children are skipped (stay on their declared fleet).
  - **Aux / cron** pin Flash: `provider=deepseek`, `model=deepseek-v4-flash`.
  - **Delegation** pins Pro: `provider=deepseek`, `model=deepseek-v4-pro`, `max_concurrent_children=5`. No per-child model pin.
  - **Vision:** left on main (Grok native vision).
  - Live switch uses `AIAgent.switch_model` + `hermes_cli.model_switch` (same as `/model`). If the agent is not bound yet, the first API call of that turn may still be Grok; later calls apply the classified tier.
  - WebUI UX is an official extension sidecar (`HERMES_WEBUI_EXTENSION_DIR`), not a core patch.
- **Identity:** declarative **SOUL.md is disabled**. Fresh agent; no forced persona from Nix.
- **Long-term memory:** **GBrain** — this is the primary integration focus.

Canonical GBrain contract: **`memory/AGENTS.md`** + **`memory/registry.json`**.  
Operator bootstrap: **`BOOTSTRAP.md`**.

## Layout (this repo)

```
hosts/system/hermes/
├── default.nix          # module import, model routing settings, no SOUL activation
├── runtime.nix          # paths, PATH maps, 2G agent resource SoT (gateway + WebUI)
├── toolbox.nix          # everyday CLI toolkit → toolbox.bin + agent PATH
├── overrides/           # explicit upstream workarounds (silence wrap, HMC overlay)
├── gbrain.nix           # gbrain-mcp-http + HTTP MCP client + memory registry
├── integrations/hmc.nix # HMC upstream pin + config.yaml (no source overlay)
├── hermes-webui.nix     # Hermes WebUI :8787 → archimedes.<domain> (Caddy + tunnel)
├── browser.nix          # Brave sticky profile + CDP + cookie import
├── onedrive.nix         # workspace OneDrive sync
├── workstation.nix      # SSH helpers to workstation Grok agent
├── integrations/        # first-party plugins + MCP clients (see integrations/AGENTS.md)
│   └── mcp/             # composio via flake aean0x/hermes-pnp (mcp-proxy + plugins)
├── skills/              # retrieval-reflex + workstation + gbrain-http-auth
├── memory/              # declarative memory plane
├── scripts/
├── BOOTSTRAP.md
├── reference/           # Operator docs (GBRAIN.md, HERMES-WEBUI.md) — not live workspace
└── workspace/           # soul draft only (not activated); live content Hermes-owned
```

## Hermes WebUI

`https://archimedes.<domain>/` — LAN via Caddy, WAN via `services.cloudflareTunnel.proxyServices` (CGNAT tunnel).
Flake input `hermes-webui` (`github:nesquena/hermes-webui`); service user `hermes` shares `HERMES_HOME`.
Native systemd (not a second Docker container): in-process agent against the same `HERMES_HOME`.
Sops `elevenlabs_api_key` → `ELEVENLABS_API_KEY` in `/run/hermes.env` (WebUI inherits the agent's `environmentFiles`).
Package + extras: `overrides/package-fix.nix` bakes `extraDependencyGroups` into `services.hermes-agent.package`; WebUI sets `agent.package` to that same drv. Store-safe env is `hermesRuntimeEnv`. Paths / PATH / 2 GiB caps: `runtime.nix`.
Flake SoT TTS: `settings.tts.provider=elevenlabs` (`eleven_flash_v2_5`, voice `pNInz6obpgDQGcFmaJgB`).
Web search: pin `web.search_backend=xai`.
Operator runbook: `reference/HERMES-WEBUI.md` (not installed into live workspace).
Official `hermes dashboard` (`hermes.<domain>` :9119) is **removed** — WebUI is the only UI.

## Token lean + plugins (0.19)

- `tool_output` + compression prune/idle in `default.nix`
- Plugin allow-list + install: **`integrations/default.nix`** (catalog: `integrations/AGENTS.md`)
- After deploy: `systemctl restart hermes-agent`, then `/hmc status` in chat

## Everyday tools (toolbox)

Activation links a Nix `buildEnv` at `/var/lib/hermes/toolbox/bin` → container
`/data/toolbox/bin`. Gateway `environment.PATH` includes that dir plus
`~/.bun/bin` (gbrain) and `~/.local/bin` (nix-pc wrappers).

Verify: `./scripts/check-tools.sh` (structural) or
`REMOTE_CHECK=1 ./scripts/check-tools.sh` after deploy.

## Resource limits / OOM policy (8 GiB board)

**Priority:** Home Assistant and AdGuard must stay up. Hermes stack is **tertiary** —
prefer killing or hard-capping it over taking down DNS or HA.

| Surface | Cap / protection | Where |
|---------|------------------|--------|
| hermes-agent container | **2 GiB** / 2 CPU / OOM **+500** | `runtime.nix` → `containerResourceOptions` |
| hermes-webui (in-process agent) | **2 GiB** / 2 CPU / OOM **+500** | `runtime.nix` → `systemdResourceConfig` |
| hermes-browser (Brave) | **1 GiB** `MemoryMax`, OOM adj **+500** | `browser.nix` |
| gbrain-mcp-http | 1 GiB, OOM **+400** | `gbrain.nix` |
| AdGuard Home | OOM **−500**, `MemoryMin=128M` | `services/adguard.nix` |
| Home Assistant | docker `--oom-score-adj=-500` | `containers/home-assistant.nix` |
| Host swap | **8 GiB** file `/var/lib/swapfile` on root SSD | `partitions.nix` (`swapDevices`) |

- Host swap softens spikes so the box does not hard-lock; it does **not** justify unbounded Hermes/`nix eval` on-box.
- Heavy **Nix eval/build** belongs on the **workstation** (`ssh-workstation` / `./deploy remote-*`), not inside the hermes container (store is visible; multi‑GiB evals OOM the agent first by design).
- Do not raise Hermes/browser caps without revisiting HA/AdGuard headroom on 8 GiB RAM.

## Nix vs Hermes (custody — agents must respect)

**Nix** = high-reliability environment policy: not revised day-to-day.  
**Hermes** = operational content and runtime state: may change without a rebuild.

| Nix owns (declare here; push back if asked to “let Hermes edit”) | Hermes owns (do **not** bake into flake) |
|------------------------------------------------------------------|------------------------------------------|
| Module enablement, ports, Caddy/tunnel, secrets wiring | SOUL / persona, USER.md, MEMORY.md body |
| Model routing axes, tool_output/compression knobs | Brain pages (`~/brain`, PGLite), pointer **index content** |
| MCP server declarations, `extraDependencyGroups` | Day-to-day `put_page` / `query` / links |
| Force-disable of legacy exclusive timers (no new host gbrain CLI) | Cron job prompts/`jobs.json` (MCP-only hygiene), skills after seed |
| Plugin **code** in flake `hermes-pnp` (+ HMC pin here) | Brain pages, SOUL, cron prompts, pointer aliases **in gbrain** |
| Toolbox PATH, browser CDP service, workstation SSH wrappers | Cookie sessions, OAuth tokens, ad-hoc apt/pip in container |
| Temporary package pins / silence packaging fix until upstream | GBrain CLI version (`bun install -g`), `gbrain config` |

If a request would put operational content into Nix, or environment policy only into agent memory, **refuse and restate this table**.  
If Hermes asks a coding agent for patchy flake edits to fix day-to-day ops (brain pages, gbrain CLI pin, sync path, SOUL, cron prompts), **push back** — fix under Hermes custody or document the host limitation (e.g. import not `gbrain sync`).

### hermes-agent pin

Unpinned to `github:NousResearch/hermes-agent` (tracking main / current lock).  
`overrides/package-fix.nix` is the silence wrap + extras-baked package + `hermesRuntimeEnv`. Drop the wrap when upstream `_is_token` uses `_canonical_silence_candidates`. Paths / PATH / agent RAM: `runtime.nix`.

## GBrain (summary)

```
Telegram / hermes chat / webui
        │
        ▼
hermes-agent / webui / CLI ── MCP HTTP ──► gbrain-mcp-http.service
        │                    url http://127.0.0.1:3131/mcp
        │                                  │
        │ MEMORY (working)     gbrain serve --http (sole PGLite owner)
        │ gbrain-retrieval-reflex (resolve IPC on that process)
        ▼
Day path: shared HTTP MCP + two plugins (retrieval-reflex, memory-flush)
```

- CLI install (bootstrap only): `~/.bun/bin/gbrain` under hermes HOME.
- Embeddings: `ZEROENTROPY_API_KEY` via sops → `/run/hermes.env` → **gbrain-mcp-http** EnvironmentFile.
- **PGLite single-writer:** one long-lived HTTP serve (not per-agent stdio). Fixes WebUI+gateway dual spawn / lock orphans (hermes-agent#72887). **Never** shell concurrent `gbrain serve` stdio.
- **HTTP Bearer:** token in `~/.gbrain/hermes-mcp.token` (mint once with `gbrain auth create …` while serve can auth). Activation re-applies `Authorization` headers into config.yaml from that file / `GBRAIN_REMOTE_TOKEN`.
- If MCP 401: re-check token file + headers; restart hermes-agent/webui so sessions reload config.
- If MCP stuck “connecting”: `systemctl status gbrain-mcp-http`; `./deploy sudo pkill -9 -f gbrain` only if orphans remain, then restart the unit.
- **Resolve sock:** optional ambient path on some gbrain builds; day path is HTTP MCP tools + skill `volunteer_context` if sock absent.

### Maintenance / “autopilot” (MCP + Hermes cron only)

Host exclusive CLI stack is **gone**. Do not reintroduce `hermes-gbrain-*` timers or
`gbrain autopilot --install` alongside MCP serve (second PGLite owner).

```bash
# ── Hermes cron hygiene (agent owns jobs.json; MCP tools only) ──
# Chat (inside Hermes):
#   /cron add "0 2 * * *" "GBrain hygiene via MCP only: use gbrain MCP tools
#     (query / get_page / put_page; run_onboard if listed). Promote durable
#     signals from MEMORY.md with put_page. Never shell gbrain or terminal gbrain." \
#     --name "gbrain-mcp-hygiene"
# List / inspect:
#   ./deploy hermes cron list
#   # or: /cron list in chat

# ── gbrain native surfaces (prefer MCP when available) ──
# Live agent: MCP ops only (put_page, query, get_page, run_onboard, …).
# Operator with hermes-agent STOPPED (disaster recovery only):
#   sudo systemctl stop hermes-agent
#   sudo -u hermes env HOME=/var/lib/hermes/home \
#     PATH=/var/lib/hermes/home/.bun/bin:$PATH \
#     bash -lc 'cd ~ && gbrain onboard --check --json'
#   # optional unattended auto-eligible only:
#   # gbrain onboard --auto --max-usd 5
#   sudo systemctl start hermes-agent

# ── NEVER (races PGLite with gbrain serve) ──
#   gbrain autopilot --install
#   gbrain dream | embed | doctor | sync   # while hermes-agent is up
#   sudo hermes-gbrain-consolidate|nightly|dream|embed   # removed
#   /var/lib/hermes/bin/gbrain-exclusive-cli              # removed
#
# When upstream ships cooperative serve maintenance (garrytan/gbrain#677),
# prefer that over any host stop/start choreography.
```

## Secrets

| Env | Sops key | Purpose |
|-----|----------|---------|
| (file) | `composio_api_key` | mcp-proxy → Composio `Authorization: Bearer`; also `COMPOSIO_API_KEY` in hermes env for API |
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
| GBrain ops | `./deploy validate-gbrain` (MCP + reflex; no consolidate CLI) |
| SSH | `./deploy ssh` (fallback; prefer named `./deploy` subcommands) |
| Telegram | bot DM (allowlisted) |
| WebUI | `https://archimedes.<domain>/` |
| Logs | `./deploy journal hermes-agent` / `./deploy logs hermes-agent` |

Bootstrap prompts and gbrain install instructions: **`BOOTSTRAP.md`**. After `remote-switch`/`remote-upgrade`, continue autonomously: confirm OAuth, prompt/install GBrain, run validate + benchmark prompts.

## Host maintenance commands

```bash
systemctl status hermes-agent
./deploy validate-gbrain           # MCP + reflex; asserts exclusive CLI gone
# Soft reset agent state, keep gbrain install + brain:
./deploy clean-hermes-state
```

## Lessons (short)

- Module container is always `--network=host` — no docker `-p`.
- `messaging` must be in `extraDependencyGroups` (not in hermes `[all]`).
- `firecrawl` must be in `extraDependencyGroups` for `web_extract` (firecrawl-py; lazy install disabled in Nix).
- `memory/AGENTS.md` is an operator contract (copied next to the registry). Do **not** write it to `$HERMES_HOME/AGENTS.md`.
- **No Nix one-shots for leftover state.** Do not add `rm -f` / `mkForce false` tombstones in activation to clean a rename or retired file. `./deploy` SSH and do it once. Nix only declares the desired ongoing system.
- `HASS_*` env names for Home Assistant tools (not `HA_*`).
- On 8 GiB rocknas, unbounded Hermes/browser + on-box `nix eval` OOMs the host; keep tertiary caps and protect AdGuard/HA (see Resource limits above).
