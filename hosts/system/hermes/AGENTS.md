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
│   ├── idealo.nix           # idealo price comparison (OAuth)
│   └── onedrive.nix
├── scripts/             # clean-hermes-state
└── BOOTSTRAP.md
```

Site git author is `settings.programs.git` (wired in `hosts/system/default.nix`). The github.com PAT helper is hermes-pnp.

## Runtime

- Official `hermes-agent` container (`ubuntu:24.04`, host net). State `/var/lib/hermes` (`/data` in the jail). Default workspace is the stateDir root (`/data`) so WebUI and gateway cwd see the whole tree (`home/`, `skills/`, `plugins/`, `workspace/`). OneDrive still copies into `workspace/onedrive`.
- WebUI + browser: hermes-pnp OCI jails (`/var/lib/hermes-oci/<name>`).
- Admin: `hermes-admin` via `/run/hermes-admin` (`admin.enable`) — status / restart / reset-failed / read-only `stats` of allowlisted units. Not sudo, not docker.sock.
- Models: `hermesPnP.modelPicker.enable = false`. Primary is `models.default` (`deepseek` / `deepseek-flash`) — session, cron, and delegation. Official `settings.fallback_model` is `xai-oauth` / `grok-4.6`. Auxiliary is flash; `free_only = true` plus `:free` OpenRouter SKU so background tasks never fall onto a paid lane. Do not set `model.context_length` (stamps every model); grok cliff is `compression.threshold_tokens = 200000` (also holds flash at 200k). Do not pin `agent.max_turns`. Do not set `hermesPnP.desktop.enable` while the agent jail is on — official `hermes serve` / `backend.mode` is native-only and conflicts with the jail.
- No declarative SOUL.md.
- WebUI: `https://archimedes.<domain>/` — Caddy LAN + Cloudflare Tunnel. Bind `127.0.0.1:8787`. Never open :8787 on WAN. TTS: ElevenLabs. Search: `web.search_backend=xai`.
- LAN alias: `https://hermes.<domain>/` — Caddy LAN/Tailscale → the same WebUI (`:8787`). No Cloudflare tunnel. The messaging gateway is `hermes-agent` (`hermes gateway run` in the jail: Telegram, cron, `api_server` `:8642`).
- Browser: Brave, CDP `:9222`, gate Caddy `browser.<domain>` → `:4848` (LAN/Tailscale only, no Cloudflare tunnel). `browser-lease` plugin serialises sessions onto one tab set; `--js-flags=--max-old-space-size=192` caps each renderer.
- OneDrive: `onedrive-sync.timer` (rclone copy into workspace, not a FUSE mount).
- mcp-proxy: enable in `default.nix`; backends in `modules/composio.nix`, `banksync.nix`, `open-banking.nix`, `openaccountants.nix`.
- BankSync: mcp-proxy injects `X-API-Key` from sops; Hermes calls `http://127.0.0.1:3140/banksync`.
- OpenAccountants: mcp-proxy `/openaccountants` (no auth, neutral UA). PolicyLayer registry is a direct HTTP MCP (`api.policylayer.com`, no proxy).
- open-banking.io: `obi-mcp-http` on `:3141` (LoadCredential → SDK in-process; no `OBI_*` env, no bundle file) → mcp-proxy `/open-banking-io`. Sidecar uses nixpkgs CPython (`uvx --python`; uv-managed CPython hits NixOS musl stub-ld) and `ExecPaths` on the state dir (`ProtectSystem=strict` otherwise noexec, cryptography `.so` cannot mmap).

## Resource limits (8 GiB — Hermes is tertiary)

Prefer killing Hermes over DNS or Home Assistant.

| Surface | Cap | Where |
|---------|-----|--------|
| hermes-agent container | 2 GiB / 1 CPU / OOM +500 | `runtime.nix` |
| hermes-webui container | 3 GiB / 2 CPU / OOM +500 | `runtime.nix` |
| hermes-browser container | 1 GiB / 2 CPU / OOM +500 | `runtime.nix` |
| gbrain-mcp-http | 512 MiB / OOM +400 | `runtime.nix` |
| obi-mcp-http | 512 MiB / OOM +400 | `modules/open-banking.nix` |
| AdGuard / HA | OOM −500 | their modules |
| minecraft (Paper + Geyser) | 3 GiB RAM + 2 GiB swap / OOM +100 | `services/minecraft.nix` |
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
- Embeddings: `gbrain.embeddingModel` = `openrouter:voyageai/voyage-4` @ 1024
  (`GBRAIN_EMBEDDING_*` on the unit). OpenRouter key via `/run/hermes.env`.
  Re-pointing vectors is `gbrain migrate embeddings` with serve stopped,
  then the Nix pin — never the pin first.
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
| `OPENROUTER_API_KEY` | `openrouter_api_key` | GBrain embeddings (`openrouter:voyageai/voyage-4`) + aux fallback |
| `ZEROENTROPY_API_KEY` | `zeroentropy_api_key` | leftover; brain migrated off zembed-1 2026-09-16. Drop after a verified query. |
| `GBRAIN_TOKEN` | not sops | GBrain HTTP MCP bearer — minted by `gbrain auth create hermes`, written to `$HERMES_HOME/.env` + `~/.gbrain/hermes-mcp.token` by `./deploy gbrain-setup`. Do not add to `hermesEnv`. |
| `HERMES_DASHBOARD_SESSION_TOKEN` | `hermes_dashboard_session_token` | Unused while the agent jail is on (Desktop / `hermes serve` is native-only). Still landed in `/run/hermes.env`. |
| `API_SERVER_KEY` | `hermes_api_server_key` | Loopback `api_server` on `:8642`. WebUI health probe (`HERMES_WEBUI_GATEWAY_BASE_URL`); without it the dashboard falls back to stale `gateway_state.json`. |
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
- Activation deep-merges `settings` into `config.yaml` and never deletes: a key an older seed wrote survives every later deploy (retired model ids keep their `compression.model_thresholds` entry). Prune such keys once with `scripts/oneshot/prune-hermes-config-keys.sh`.
