# Bootstrap: fresh Hermes + GBrain on rocknas

Target end state: **xAI OAuth + Grok 4.5**, empty identity (no declarative SOUL), **GBrain MCP + CLI** ready, ZeroEntropy embeddings secret in `/run/hermes.env`.

North-star behavior: `~/dev/hetzner-nixos` GBrain integration. Layout here lives under `hosts/system/hermes/`.

---

## 0. Prerequisites (workstation)

```bash
# Secrets (ZeroEntropy + Firecrawl land in hermesEnv as ZEROENTROPY_API_KEY / FIRECRAWL_API_KEY)
cd secrets && ./decrypt          # edit secrets.yaml.work if rotating keys
# ... edit (set zeroentropy_api_key, firecrawl_api_key, …) ...
./encrypt                        # writes secrets.yaml

# Deploy config
git add hosts/system/hermes secrets
./deploy remote-switch           # or remote-test first
```

On device after switch:

```bash
systemctl status hermes-agent
ls -la /var/lib/hermes/memory/          # registry.json, AGENTS.md, export-schema.json
ls -la /var/lib/hermes/.hermes/AGENTS.md  # live memory contract (not SOUL)
grep -E 'ZEROENTROPY|FIRECRAWL' /run/hermes.env | sed 's/=.*/=…/'
# web_extract needs firecrawl-py (extraDependencyGroups) + FIRECRAWL_API_KEY
```

---

## 1. Bootstrap the agent (OAuth + model)

Declarative config already sets:

```nix
settings.model.provider = "xai-oauth";
settings.model.default = "grok-4.5";
```

**One-time OAuth** (interactive; cannot be fully declarative without `authFile`):

```bash
# From workstation:
./deploy ssh
# On device as admin:
hermes auth add xai-oauth
# Complete browser flow; tokens land in /var/lib/hermes/.hermes/auth.json
# Restart gateway so MCP/children see credentials:
sudo systemctl restart hermes-agent
```

**Talk to the agent** (pick one):

| Channel | How |
|---------|-----|
| Host CLI | `hermes chat` (sudo-routed into container) |
| Telegram | DM the bot (allowlist from `TELEGRAM_ALLOWED_USERS`) |
| Dashboard | `https://hermes.<domain>/` (LAN) |

**Smoke prompts (agent bootstrap):**

```
What model and provider are you using right now?
```

```
Run a short terminal command: `uname -a` and report the output.
```

If OAuth is missing, doctor will complain:

```bash
hermes doctor
```

Optional API-key fallback (already in sops as `XAI_API_KEY`): set provider to `xai` temporarily only if OAuth is blocked — prefer fixing OAuth.

**Identity:** Do **not** restore declarative SOUL. Leave `SOUL.md` absent or agent-written. `workspace/soul.md` in the repo is a draft only and is **not** activated.

---

## 2. Bootstrap GBrain (post-install catalogue)

### Declarative (Nix — already after `remote-switch`)

| Piece | Where |
|-------|--------|
| HTTP sole PGLite owner | `gbrain-mcp-http.service` (`gbrain serve --http :3131`) |
| Hermes MCP client | `mcpServers.gbrain.url = http://127.0.0.1:3131/mcp` |
| Bearer re-apply on activation | token file `~/.gbrain/hermes-mcp.token` or `GBRAIN_REMOTE_TOKEN` |
| Plugins | `gbrain-retrieval-reflex`, `gbrain-memory-flush`, `model-router` |
| Memory contract | `memory/AGENTS.md`, registry, export schema |
| `ZEROENTROPY_API_KEY` | sops → `/run/hermes.env` → HTTP unit + agents |

### One-shot / Hermes-home (must still run once)

| Step | What |
|------|------|
| 1 | Install **bun** + **gbrain CLI** (`bun install -g github:garrytan/gbrain`) under hermes HOME |
| 2 | `gbrain init --pglite` if no `~/.gbrain/brain.pglite` |
| 3 | `~/brain` git tree; `gbrain config set search.mode balanced` |
| 4 | Mint HTTP bearer: `gbrain auth create hermes-agents` → token file + `GBRAIN_REMOTE_TOKEN` in `.hermes/.env` (Hermes env, **not** sops) |
| 5 | Wire `config.yaml` with **literal** `Bearer <token>` (never `${GBRAIN_REMOTE_TOKEN}`) — skill `gbrain-http-auth` / `gbrain-setup` |
| 6 | Import markdown: stop serve → `gbrain import ~/brain --no-embed` |
| 7 | Embed: `gbrain embed --stale` with ZE (serve still stopped) |
| 8 | Start `gbrain-mcp-http`, restart `hermes-agent` (+ webui) |
| 9 | Smoke: `curl :3131/health`, `hermes mcp test gbrain` |

**Never on this host:** `gbrain autopilot --install` (second writer); exclusive consolidate/dream; stdio multi-serve; soul-audit for SOUL.

Upstream install steps only: **https://raw.githubusercontent.com/garrytan/gbrain/master/INSTALL_FOR_AGENTS.md**

### 2a. Operator one-shot (preferred)

```bash
# From workstation after remote-switch (copies + runs on device):
./deploy gbrain-setup
# or on device as root:
sudo bash hosts/system/hermes/scripts/gbrain-setup.sh
```

### 2b. Agent-assisted

```bash
./deploy hermes chat -Q --yolo --accept-hooks -q "$(cat hosts/system/hermes/prompts/gbrain-bootstrap-query.txt)"
```

### 2c. Validate

```bash
./deploy validate-gbrain
./deploy systemctl is-active gbrain-mcp-http hermes-agent
./deploy curl -sS http://127.0.0.1:3131/health
./deploy hermes mcp test gbrain
```

Expect: one HTTP serve, bearer MCP tools, two plugins, no exclusive CLI.

---

## 3. Day-2 operations

| Action | How |
|--------|-----|
| Durable write / recall | Agent MCP `put_page` / `query` / `get_page` only |
| Brain hygiene | gbrain MCP ops (e.g. onboard) or Hermes cron **via MCP tools** — never shell `gbrain` |
| Rotate ZeroEntropy | `secrets/decrypt` → edit → `encrypt` → `remote-switch` → `systemctl restart hermes-agent` |
| Soft reset agent, keep gbrain | `./deploy clean-hermes-state` (preserves `~/brain`, `~/.bun`) |

**Policy:** MCP + reflex only. Host exclusive consolidate/dream/embed/nightly **removed**. Do not run `gbrain` CLI while hermes-agent is up (PGLite single-writer). Operator CLI only with agent **stopped** for disaster recovery.

**PGLite WASM Aborted:** data dir damage (not “MEMORY full”).  
See `reference/GBRAIN.md` → recovery: ensure `gbrain-mcp-http` sole owner; reimport `~/brain` only if needed.

---

## 4. Path map (host ↔ container)

See `memory/registry.json` and `memory/AGENTS.md` (canonical). Short form:

| Concern | Host | Container |
|---------|------|-----------|
| Memory AGENTS | `/var/lib/hermes/memory/AGENTS.md` | `/data/memory/AGENTS.md` |
| Live AGENTS | `/var/lib/hermes/.hermes/AGENTS.md` | `/data/.hermes/AGENTS.md` |
| Export plane | `…/memories/export/` | `/data/.hermes/memories/export/` |
| GBrain home | `/var/lib/hermes/home/.gbrain` | `/home/hermes/.gbrain` |
| Brain git | `/var/lib/hermes/home/brain` | `/home/hermes/brain` |
| bun / gbrain CLI | `…/home/.bun` | `/home/hermes/.bun/bin` |

---

## 5. What is declarative vs not

| Piece | Declarative? |
|-------|----------------|
| `mcpServers.gbrain` | Yes (`gbrain.nix`) |
| Registry + export schema + memory AGENTS.md | Yes (activation, always) |
| Host exclusive gbrain CLI / dream timers | **No** (removed; MCP + Hermes cron only) |
| Plugin **code** (gbrain-retrieval-reflex, memory-flush, tool-call-coherency, HMC) | Yes (activation) |
| `ZEROENTROPY_API_KEY` | Yes (sops → hermesEnv) |
| `FIRECRAWL_API_KEY` | Yes (sops → hermesEnv; `web_extract`) |
| `firecrawl` pyproject extra | Yes (`extraDependencyGroups`) |
| Model provider `xai-oauth` + default `grok-4.5` | Yes |
| SOUL.md / persona docs | **No** (disabled) |
| Operator refs (`reference/GBRAIN.md`, `HERMES-WEBUI.md`) | Repo only — not live workspace |
| retrieval-reflex skill | Yes (always managed; gbrain-native policy) |
| `gbrain` CLI install (bun) | **No** — agent or manual (this bootstrap) |
| xAI OAuth tokens | **No** — `hermes auth add xai-oauth` once (or future `authFile`) |
| Local Brave + CDP (`browser.nix`) | Yes (service + profile dir); warm via `hermes-browser-import-cookies` |

---

## 6. Local browser (CDP) + phone noVNC handoff

Primary automation browser is **local** (household/Starlink egress + sticky profile), not Browserless. Browserless remains for disposable scraping only.

After deploy:

- `hermes-browser.service` — Xvfb + **Brave**, profile `/var/lib/hermes/browser-profile`, CDP `http://127.0.0.1:9222` (loopback)
- Warm cookies (Netscape `.txt` or Playwright JSON): drop under `/var/lib/hermes/browser-cookies/` then  
  `sudo -u hermes hermes-browser-import-cookies /var/lib/hermes/browser-cookies/ra-axs.json`  
  (imports via CDP while Brave stays up; session + stable cookies only — not password dumps)
- `hermes-browser-vnc.service` — x11vnc on the same display (password file)
- `hermes-browser-novnc.service` — noVNC web UI on **port 6080** (phone browser)

```bash
hermes-browser-status
systemctl status hermes-browser hermes-browser-vnc hermes-browser-novnc
curl -sS http://127.0.0.1:9222/json/version
# password (agent can read and Telegram you):
grep NOVNC /run/hermes-browser-vnc.env
```

**Phone hybrid (when agent hits CF/AXS):**

1. Agent keeps the CDP session open and sends you `HERMES_BROWSER_NOVNC_URL` + password.
2. On phone (Tailscale or LAN): open the noVNC link, enter password, tap the captcha in that live view.
3. Reply `done` — agent continues checkout with the **same cookies**.

Cellular without Tailscale will not reach LAN-only NAS; use Tailscale.

**Cold profile still fails hard gates** until warmed once via noVNC or cookie import.

---

## 7. Hermes WebUI (chat frontend)

Native `services.hermes-webui` (flake `hermes-webui`) on **127.0.0.1:8787**.
LAN: Caddy `archimedes.<domain>`. WAN: Cloudflare Tunnel (`services.cloudflareTunnel.proxyServices`).
WebUI runs the agent **in-process** against `HERMES_HOME` (`/var/lib/hermes/.hermes`).
Optional loopback API still on **:8642** for scripts. Dashboard (`hermes.<domain>`) is LAN-only.

Full runbook: **`reference/HERMES-WEBUI.md`**.

| Path | Role |
|------|------|
| `/run/hermes.env` | `API_SERVER_KEY`, `ELEVENLABS_API_KEY`, static API_SERVER_* knobs |
| `/run/hermes-webui.env` | `ELEVENLABS_API_KEY` (server-side TTS) |

```bash
systemctl status hermes-agent hermes-webui
curl -sS http://127.0.0.1:8787/health
curl -sS http://127.0.0.1:8642/health
```

Open `https://archimedes.<domain>/`. TTS engine → **ElevenLabs** when key is present.
After adding the hostname, re-run `./scripts/setup-cloudflare-tunnel.sh` so DNS CNAME exists.

---

## 8. Token lean + hermes-context-manager (HMC)

Settings live in `default.nix` (`tool_output`, compression prune/idle). Plugin pin + config in `context-manager.nix`.

```bash
# After remote-switch — restart so HMC hooks load:
systemctl restart hermes-agent
# In chat: /hmc status
ls -la /var/lib/hermes/plugins/hermes-context-manager/
ls -la /var/lib/hermes/.hermes/plugins/hermes-context-manager  # → ../../plugins/...
```

Dashboard stays off until `/hmc dashboard action=start`.

**gbrain-retrieval-reflex** (ambient resolve IPC → live serve) and **tool-call-coherency** install with gbrain activation; enable list includes them plus HMC + memory-flush. No static pointer JSON.
