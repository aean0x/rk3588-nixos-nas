# Hermes Agent — rocknas

Composer SoT: **`hermes.nix`** (`services.hermesPnP` + official settings + public edge).  
Host runtime (2G caps, sudo CLI): **`runtime.nix`**.  
Leftovers: **`modules/`** (GBrain Bearer/git-credential/1G, Composio, OneDrive, workstation extraSkills).

First-boot: **`BOOTSTRAP.md`**. GBrain operator scripts live in flake input **hermes-pnp** (`./deploy gbrain-setup` / `validate-gbrain`).

## Layout

```
hosts/system/hermes/
├── hermes.nix           # composer + official settings + Caddy/tunnel
├── runtime.nix          # 2G agent RAM/CPU + sudo hermes CLI
├── modules/
│   ├── gbrain.nix       # site leftovers (Bearer rewrite, git-credential, 1G)
│   ├── composio.nix     # hermesPnP.mcpProxy.backends.composio
│   ├── onedrive.nix
│   └── workstation.nix  # wrappers + hermesPnP.skills.extraSkills
├── skills/workstation/  # extraSkills tree (SKILL.md at root)
├── scripts/             # clean-hermes-state + git-credential helper
└── BOOTSTRAP.md
```

## Runtime

- Official `hermes-agent` container (`ubuntu:24.04`, host net). State `/var/lib/hermes` (`/data` in the jail).
- WebUI + browser: composer OCI jails (`/var/lib/hermes-oci/<name>` identity). Privilege locks are injected after extraOptions.
- Models: PnP `low`/`medium`/`high` (deepseek flash / pro / xai-oauth grok-4.6). WebUI extension sidecar from composer.
- No declarative SOUL.md.
- WebUI: `https://archimedes.<domain>/` — Caddy LAN + Cloudflare Tunnel. Bind `127.0.0.1:8787`. Never open :8787 on WAN. TTS: ElevenLabs (`DfE5EkknFF950NR6OMui`, `eleven_flash_v2_5`). Search: `web.search_backend=xai`.
- Toolbox + browser CDP + agent-browser gate: composer. Engine here is Brave. Gate is Caddy `browser.<domain>` → `:4848` (LAN/Tailscale only, no Cloudflare tunnel). `cdpAllowOrigins` includes `gate.publicUrl`.
- mcp-proxy: composer `clientAuth=token`. Site backends + filters stay in `modules/composio.nix`.

## Resource limits (8 GiB — Hermes is tertiary)

Prefer killing Hermes over DNS or Home Assistant.

| Surface | Cap | Where |
|---------|-----|--------|
| hermes-agent container | 2 GiB / 2 CPU / OOM +500 | `runtime.nix` |
| hermes-webui container | 2 GiB / 2 CPU / OOM +500 | `runtime.nix` (`webui.container.extraOptions`) |
| hermes-browser container | 1 GiB / 2 CPU / OOM +500 | `runtime.nix` (`browser.container.extraOptions`) |
| gbrain-mcp-http | 1 GiB / OOM +400 | `modules/gbrain.nix` (unit is composer) |
| AdGuard / HA | OOM −500 | their modules |
| Host swap | 8 GiB | `partitions.nix` |

Heavy Nix eval/build → workstation (`./deploy remote-*`), not on-box Hermes.

## Nix vs Hermes custody

| Nix owns | Hermes owns |
|----------|-------------|
| Module enablement, ports, Caddy/tunnel, secrets wiring | SOUL / persona, USER.md, MEMORY.md body |
| Model routing, tool_output/compression | Brain pages, pointer index content |
| MCP declarations, extraDependencyGroups | Day-to-day put_page / query |
| Plugin **code** in hermes-pnp | Cron prompts, gbrain CLI version |
| Toolbox PATH, browser CDP, workstation wrappers | Cookies, OAuth tokens, ad-hoc apt/pip |

Do not bake operational content into the flake. Do not put environment policy only in agent memory.

## GBrain

`hermesPnP.gbrain.enable` starts `gbrain-mcp-http` (`gbrain serve --http :3131`).  
Host leftover re-applies literal Bearer into `config.yaml`.

- CLI: bun-global under hermes HOME (`./deploy gbrain-setup`).
- Embeddings: `ZEROENTROPY_API_KEY` via `/run/hermes.env`.
- **Never** shell `gbrain` while the agent is up (PGLite single-writer).
- Hygiene: MCP tools or Hermes cron **via MCP only**. No exclusive consolidate/dream/embed.
- Protocol SoT: GBrain page `ops/gbrain-protocol`. Composer operator doc: hermes-pnp `docs/gbrain.md`.

```
Telegram / chat / webui → hermes-agent ── MCP HTTP ──► gbrain-mcp-http
                              MEMORY (working)           gbrain serve (sole writer)
                              retrieval-reflex + memory-flush
```

## Secrets

| Env / file | Sops | Purpose |
|------------|------|---------|
| file | `composio_api_key` | mcp-proxy Bearer + `COMPOSIO_API_KEY` |
| `ZEROENTROPY_API_KEY` | `zeroentropy_api_key` | GBrain embeddings |
| `FIRECRAWL_API_KEY` | `firecrawl_api_key` | web_extract |
| `BRAVE_API_KEY` | `brave_search_api_key` | Web search |
| `XAI_API_KEY` | `xai_api_key` | Fallback (OAuth is primary) |
| `TELEGRAM_*` | telegram | Gateway |
| file | `nix_pc_agent_ssh_key` | `ssh-workstation` IdentityFile only |

`cd secrets && ./decrypt` → edit → `./encrypt` → `./deploy remote-test`.

## Workstation

`modules/workstation.nix` + `skills.extraSkills.workstation`. Not MCP. Host on; checkout latch; key never in hermes HOME.

```bash
checkout-workstation
ssh-workstation 'bash -lc "grok --always-approve -p …"'
release-workstation
```

## Talk to the agent

Drive these via `./deploy` — do not wait for the human.

| Method | Command |
|--------|---------|
| CLI | `./deploy hermes chat` / `doctor` / `mcp list` |
| GBrain | `./deploy validate-gbrain` / `gbrain-setup` |
| WebUI | `https://archimedes.<domain>/` |
| Logs | `./deploy journal hermes-agent` |
| Soft reset | `./deploy clean-hermes-state` |

## Lessons

- Container is `--network=host` — no docker `-p`.
- `messaging` and `firecrawl` must be in `extraDependencyGroups`.
- Do not write a Nix manifesto to `$HERMES_HOME/AGENTS.md`.
- No Nix one-shots for leftover state — `./deploy` SSH once.
- `HASS_*` for Home Assistant tools (not `HA_*`).
- Do not raise Hermes/browser caps without revisiting HA/AdGuard headroom.
