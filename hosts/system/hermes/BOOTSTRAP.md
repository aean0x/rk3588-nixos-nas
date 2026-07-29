# Bootstrap: fresh Hermes + GBrain on rocknas

Target end state: **xAI OAuth + Grok 4.5**, empty identity (no declarative SOUL), **GBrain MCP + CLI** ready, ZeroEntropy embeddings secret in `/run/hermes.env`.

North-star behavior: `~/dev/hetzner-nixos` GBrain integration. Layout here lives under `hosts/system/hermes/`.

---

## 0. Prerequisites (workstation)

```bash
# Secrets (ZeroEntropy already in hermesEnv as ZEROENTROPY_API_KEY)
cd secrets && ./decrypt          # edit secrets.yaml.work if rotating keys
# ... edit ...
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
grep ZEROENTROPY /run/hermes.env | sed 's/=.*/=…/'
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

## 2. Bootstrap GBrain (install CLI + brain + MCP)

GBrain is **not** a Nix package. CLI is a **bun global** under `/var/lib/hermes/home/.bun` → container `/home/hermes/.bun/bin/gbrain`. MCP is declarative (`services.hermes-agent.mcpServers.gbrain` → `gbrain serve`).

### 2a. Preferred: prompt the agent (headless install)

Agents should run this themselves:

```bash
./deploy hermes chat -Q --yolo --accept-hooks -q "$(cat hosts/system/hermes/prompts/gbrain-bootstrap-query.txt)"
# or paste the prompt into Telegram / dashboard
```

Canonical agent install doc (fetch, do not invent steps):

**https://raw.githubusercontent.com/garrytan/gbrain/master/INSTALL_FOR_AGENTS.md**

Operator-friendly one-shot CLI path (same end state):

```bash
# inside container as hermes (HOME persists under /var/lib/hermes/home)
curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"
bun install -g github:garrytan/gbrain
gbrain init --pglite    # or: gbrain init
gbrain config set search.mode balanced   # cost-safe default for this NAS
gbrain doctor
```

If `bun install -g` breaks postinstall, clone+`bun link` recovery per install doc (#218).

**Do not skip:** agent must **fetch INSTALL_FOR_AGENTS.md** (or the CLI path above). Skip soul-audit / persona generation on this host (SOUL is intentionally non-declarative).

### 2b. Operator fallback (manual docker)

```bash
sudo docker exec -u hermes -it hermes-agent bash
# inside container:
export PATH="$HOME/.bun/bin:$PATH"
# install bun if needed, then follow upstream install.md for gbrain
gbrain --help
gbrain list -n 3
exit

sudo systemctl restart hermes-agent
hermes mcp list   # expect gbrain when CLI is on PATH
```

### 2c. Validate integration

On device (after `remote-switch`):

```bash
# Structural + timer checks (from this repo; scp if needed)
sudo bash /path/to/hosts/system/hermes/scripts/validate-gbrain-integration.sh
# or after switch if installed under state:
# host packages: hermes-gbrain-consolidate, hermes-gbrain-embed
sudo hermes-gbrain-consolidate
systemctl list-timers | grep -E 'gbrain|hermes-gbrain'
```

Workstation helper (once wired in deploy):

```bash
./deploy validate-gbrain
```

---

## 3. Day-2 operations

| Action | Command |
|--------|---------|
| Daily consolidate (Hermes export → gbrain put + dream) | `sudo hermes-gbrain-consolidate` |
| Embed refresh | `sudo hermes-gbrain-embed` / timer Sun 05:00 |
| Dream only | timer 04:30 / `gbrain dream` in container with lock |
| Rotate ZeroEntropy | `secrets/decrypt` → edit → `encrypt` → `remote-switch` → `systemctl restart hermes-agent` |
| Soft reset agent, keep gbrain | `sudo bash …/clean-hermes-state.sh` (preserves `~/brain`, `~/.bun`) |

**Anti-clobber:** timers `pkill -f 'gbrain serve'` before maintenance so PGLite is not shared with MCP.

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
| Registry + export schema + memory AGENTS.md | Yes (activation) |
| Timers consolidate / dream / embed | Yes |
| `ZEROENTROPY_API_KEY` | Yes (sops → hermesEnv) |
| Model provider `xai-oauth` + default `grok-4.5` | Yes |
| SOUL.md / persona docs | **No** (disabled) |
| `gbrain` CLI install (bun) | **No** — agent or manual (this bootstrap) |
| xAI OAuth tokens | **No** — `hermes auth add xai-oauth` once (or future `authFile`) |
| Local Chromium + CDP (`browser.nix`) | Yes (service + profile dir); **warm cookies** still need a human once |

---

## 6. Local browser (CDP) + phone noVNC handoff

Primary automation browser is **local** (household/Starlink egress + sticky profile), not Browserless. Browserless remains for disposable scraping only.

After deploy:

- `hermes-browser.service` — Xvfb + Chromium, profile `/var/lib/hermes/browser-profile`, CDP `http://127.0.0.1:9222` (loopback)
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
