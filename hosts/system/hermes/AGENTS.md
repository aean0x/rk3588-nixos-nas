# Hermes Agent

`default.nix` is the hermes-pnp consumer: `services.hermesPnP`, official `services.hermes-agent` settings, and the public edge. RAM caps and `hermes-admin` live in `runtime.nix`.

First boot: **BOOTSTRAP.md**. GBrain operator scripts live in flake input **hermes-pnp** (`./deploy gbrain-setup` / `validate-gbrain`).

## Layout

```
hosts/system/hermes/
├── default.nix          # hermesPnP + official settings + Caddy/tunnel
├── runtime.nix          # RAM caps + hermes-admin + sudo CLI
├── modules/
│   ├── composio.nix         # hermesPnP.mcpProxy.backends.composio
│   ├── banksync.nix         # mcp-proxy → mcp.banksync.io (X-API-Key)
│   ├── open-banking.nix     # loopback obi-mcp-http + mcp-proxy
│   ├── openaccountants.nix  # mcp-proxy → openaccountants.com (no auth)
│   ├── policylayer.nix      # direct HTTP PolicyLayer registry
│   └── onedrive.nix
├── scripts/             # clean-hermes-state
└── BOOTSTRAP.md
```

Site git author is `settings.programs.git` (wired in `hosts/system/default.nix`). The github.com PAT helper is hermes-pnp.

## Runtime

- Official `hermes-agent` container (`ubuntu:24.04`, host net). State `/var/lib/hermes` (`/data` in the jail). Default workspace is the stateDir root (`/data`) so WebUI and gateway cwd see the whole tree (`home/`, `skills/`, `plugins/`, `workspace/`). OneDrive still copies into `workspace/onedrive`.
- WebUI + browser: hermes-pnp OCI jails (`/var/lib/hermes-oci/<name>`).
- Admin restarts: `hermes-admin` via `/run/hermes-admin` (`admin.enable`). Not sudo, not docker.sock.
- Models: `hermesPnP.models` low/medium/high (deepseek-v4-flash / pro / xai-oauth grok-4.6). Split is only those three. `hermesPnP.model.default = "high"` (library default is `medium`). model-router **v0.8.5**: Auto classifies all three (Quick / Standard / Expert), sticky prev-tier (high never sticks), compact-on-switch; `high` is money over $20 / irreversible / security. Slot model/provider/label/short/best_for are Nix options (generated config.json is the Python handoff). Fallback is deepseek-v4-pro. Auxiliary: `free_only = true` plus `:free` OpenRouter SKU so background tasks never fall onto a paid lane. Do not set `model.context_length` (stamps every model); grok cliff is `compression.threshold_tokens`. Do not pin `agent.max_turns`.
- No declarative SOUL.md.
- WebUI: `https://archimedes.<domain>/` — Caddy LAN + Cloudflare Tunnel. Bind `127.0.0.1:8787`. Never open :8787 on WAN. TTS: ElevenLabs. Search: `web.search_backend=xai`.
- App/gateway: `https://hermes.<domain>/` — Caddy LAN/Tailscale → `hermes serve` `:9119` (`/api/ws`, `/api/pty`). Headless backend; dashboard UI is not required. Session token: `$HERMES_HOME/desktop-session.token` (minted on first `hermes-serve` start). No Cloudflare tunnel.
- Browser: Brave, CDP `:9222`, gate Caddy `browser.<domain>` → `:4848` (LAN/Tailscale only, no Cloudflare tunnel).
- OneDrive: `onedrive-sync.timer` (rclone copy into workspace, not a FUSE mount).
- mcp-proxy: enable in `default.nix`; backends in `modules/composio.nix`, `banksync.nix`, `open-banking.nix`, `openaccountants.nix`.
- BankSync: mcp-proxy injects `X-API-Key` from sops; Hermes calls `http://127.0.0.1:3140/banksync`.
- OpenAccountants: mcp-proxy `/openaccountants` (no auth, neutral UA). PolicyLayer registry is a direct HTTP MCP (`api.policylayer.com`, no proxy).
- open-banking.io: `obi-mcp-http` on `:3141` (LoadCredential → SDK in-process; no `OBI_*` env, no bundle file) → mcp-proxy `/open-banking-io`. Sidecar uses nixpkgs CPython (`uvx --python`; uv-managed CPython hits NixOS musl stub-ld) and `ExecPaths` on the state dir (`ProtectSystem=strict` otherwise noexec, cryptography `.so` cannot mmap).

## Resource limits (8 GiB — Hermes is tertiary)

Prefer killing Hermes over DNS or Home Assistant.

| Surface | Cap | Where |
|---------|-----|--------|
| hermes-agent container | 1 GiB / 1 CPU / OOM +500 | `runtime.nix` |
| hermes-webui container | 2 GiB / 2 CPU / OOM +500 | `runtime.nix` |
| hermes-browser container | 1 GiB / 2 CPU / OOM +500 | `runtime.nix` |
| gbrain-mcp-http | 512 MiB / OOM +400 | `runtime.nix` |
| obi-mcp-http | 512 MiB / OOM +400 | `modules/open-banking.nix` |
| AdGuard / HA | OOM −500 | their modules |
| Host swap | 8 GiB | `partitions.nix` |

Heavy Nix eval/build → workstation (`./deploy remote-*`), not on-box Hermes.

## Nix vs Hermes custody

| Nix owns | Hermes owns |
|----------|-------------|
| Module enablement, ports, Caddy/tunnel, secrets wiring | SOUL / persona, USER.md, MEMORY.md body |
| Model routing, compression.threshold_tokens | Brain pages, thin MEMORY working notes |
| MCP declarations, extraDependencyGroups | Day-to-day put_page / query |
| Plugin code in hermes-pnp | Cron prompts, gbrain CLI version |
| Toolbox PATH, browser CDP | Cookies, OAuth tokens, ad-hoc apt/pip |

Do not bake operational content into the flake. Do not put environment policy only in agent memory.

## GBrain

`hermesPnP.gbrain.enable` starts `gbrain-mcp-http` (`gbrain serve --http :3131`),
sets the MCP URL + `Authorization: Bearer ${GBRAIN_TOKEN}` (env-ref, expanded
from `$HERMES_HOME/.env`).

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
| `MCP_PROXY_TOKEN` | not sops | mcp-proxy client token (`/var/lib/mcp-proxy/client.env`) merged into `$HERMES_HOME/.env` by hermes-pnp. Do not add to `hermesEnv` — rebuilds would desync it from `client.token`. |
| file | `composio_api_key` | mcp-proxy Bearer |
| file | `banksync_api_key` | mcp-proxy `X-API-Key` (not in hermes env) |
| file | `obi_api_key` / `obi_private_key` / `obi_base_url` | `obi-mcp-http` LoadCredential (not in hermes env) |
| `ZEROENTROPY_API_KEY` | `zeroentropy_api_key` | GBrain embeddings |
| `GBRAIN_TOKEN` | not sops | GBrain HTTP MCP bearer — minted by `gbrain auth create hermes`, written to `$HERMES_HOME/.env` + `~/.gbrain/hermes-mcp.token` by `./deploy gbrain-setup`. Do not add to `hermesEnv`. |
| `HERMES_DASHBOARD_SESSION_TOKEN` | not sops | Desktop remote-control token. Runtime file `$HERMES_HOME/desktop-session.token` (mode 0600), minted on first `hermes-serve` start, exported by the unit launcher. Do not add to `hermesEnv` or `.env` (activation rewrites `.env`; dotenv `override=True` would clobber a spawn token). |
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
