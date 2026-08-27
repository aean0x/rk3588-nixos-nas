# Hermes Agent

`default.nix` is the hermes-pnp consumer: `services.hermesPnP`, official `services.hermes-agent` settings, and the public edge. RAM caps and `hermes-admin` live in `runtime.nix`.

First boot: **BOOTSTRAP.md**. GBrain operator scripts live in flake input **hermes-pnp** (`./deploy gbrain-setup` / `validate-gbrain`).

## Layout

```
hosts/system/hermes/
├── default.nix          # hermesPnP + official settings + Caddy/tunnel
├── runtime.nix          # RAM caps + hermes-admin + sudo CLI
├── modules/
│   ├── composio.nix     # hermesPnP.mcpProxy.backends.composio
│   └── onedrive.nix
├── scripts/             # clean-hermes-state
└── BOOTSTRAP.md
```

Site git author is `settings.programs.git` (wired in `hosts/system/default.nix`). The github.com PAT helper is hermes-pnp.

## Runtime

- Official `hermes-agent` container (`ubuntu:24.04`, host net). State `/var/lib/hermes` (`/data` in the jail). Default workspace is the stateDir root (`/data`) so WebUI and gateway cwd see the whole tree (`home/`, `skills/`, `plugins/`, `workspace/`). OneDrive still copies into `workspace/onedrive`.
- WebUI + browser: hermes-pnp OCI jails (`/var/lib/hermes-oci/<name>`).
- Admin restarts: `hermes-admin` via `/run/hermes-admin` (`admin.enable`). Not sudo, not docker.sock.
- Models: `hermesPnP.models` low/medium/high (deepseek-v4-flash / pro / xai-oauth grok-4.6). Split is only those three. model-router **v0.8.2**: Auto classifies all three (Quick / Standard / Expert); `high` is money over $20 / irreversible / security. Slot model/provider/label/short/best_for are Nix options (generated config.json is the Python handoff). Fallback is deepseek-v4-pro. Do not set `model.context_length` (stamps every model); grok cliff is `compression.threshold_tokens`. Do not pin `agent.max_turns`.
- No declarative SOUL.md.
- WebUI: `https://archimedes.<domain>/` — Caddy LAN + Cloudflare Tunnel. Bind `127.0.0.1:8787`. Never open :8787 on WAN. TTS: ElevenLabs. Search: `web.search_backend=xai`.
- Browser: Brave, CDP `:9222`, gate Caddy `browser.<domain>` → `:4848` (LAN/Tailscale only, no Cloudflare tunnel).
- OneDrive: `onedrive-sync.timer` (rclone copy into workspace, not a FUSE mount).
- mcp-proxy: enable in `default.nix`; Composio backends + filters in `modules/composio.nix`.

## Resource limits (8 GiB — Hermes is tertiary)

Prefer killing Hermes over DNS or Home Assistant.

| Surface | Cap | Where |
|---------|-----|--------|
| hermes-agent container | 1 GiB / 1 CPU / OOM +500 | `runtime.nix` |
| hermes-webui container | 2 GiB / 2 CPU / OOM +500 | `runtime.nix` |
| hermes-browser container | 1 GiB / 2 CPU / OOM +500 | `runtime.nix` |
| gbrain-mcp-http | 512 MiB / OOM +400 | `runtime.nix` |
| AdGuard / HA | OOM −500 | their modules |
| Host swap | 8 GiB | `partitions.nix` |

Heavy Nix eval/build → workstation (`./deploy remote-*`), not on-box Hermes.

## Nix vs Hermes custody

| Nix owns | Hermes owns |
|----------|-------------|
| Module enablement, ports, Caddy/tunnel, secrets wiring | SOUL / persona, USER.md, MEMORY.md body |
| Model routing, compression.threshold_tokens | Brain pages, pointer index content |
| MCP declarations, extraDependencyGroups | Day-to-day put_page / query |
| Plugin code in hermes-pnp | Cron prompts, gbrain CLI version |
| Toolbox PATH, browser CDP | Cookies, OAuth tokens, ad-hoc apt/pip |

Do not bake operational content into the flake. Do not put environment policy only in agent memory.

## GBrain

`hermesPnP.gbrain.enable` starts `gbrain-mcp-http` (`gbrain serve --http :3131`),
sets the MCP URL, and writes a literal Bearer into `config.yaml`.

- CLI: bun-global under hermes HOME (`./deploy gbrain-setup`).
- Embeddings: `ZEROENTROPY_API_KEY` via `/run/hermes.env`.
- **Never** shell `gbrain` while the agent is up (PGLite single-writer).
- Hygiene: MCP tools or Hermes cron **via MCP only**.
- Protocol SoT: GBrain page `ops/gbrain-protocol`. Operator doc: hermes-pnp `docs/gbrain.md`.

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

`cd secrets && ./decrypt` → edit → `./encrypt` → `./deploy remote-test`.

## Talk to the agent

Drive these via `./deploy` — do not wait for the human.

| Method | Command |
|--------|---------|
| CLI | `./deploy hermes chat` / `doctor` / `mcp list` |
| GBrain | `./deploy validate-gbrain` / `gbrain-setup` |
| WebUI | `https://archimedes.<domain>/` |
| Logs | `./deploy journal hermes-agent` |
| Soft reset | `./deploy clean-hermes-state` |

## Gotchas

- Container is `--network=host` — no docker `-p`.
- `messaging` and `firecrawl` must be in `extraDependencyGroups`.
- `HASS_*` for Home Assistant tools (not `HA_*`).
- Do not raise Hermes/browser caps without revisiting HA/AdGuard headroom.
- No Nix one-shots for retired files — `./deploy` SSH once.
