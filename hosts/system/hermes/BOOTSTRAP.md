# Bootstrap: fresh Hermes + GBrain

End state: xAI OAuth + Grok 4.6, no declarative SOUL, GBrain HTTP MCP up,
ZeroEntropy in `/run/hermes.env`.

## 0. Secrets + deploy

```bash
cd secrets && ./decrypt   # set zeroentropy_api_key, firecrawl_api_key, …
./encrypt
git add hosts/system/hermes secrets
./deploy remote-switch    # or remote-test first
```

On device:

```bash
systemctl status hermes-agent gbrain-mcp-http hermes-webui
grep -E 'ZEROENTROPY|FIRECRAWL' /run/hermes.env | sed 's/=.*/=…/'
```

## 1. One-time OAuth

Declarative: `hermesPnP.models.high` → `xai-oauth` / `grok-4.6`.

```bash
./deploy ssh
hermes auth add xai-oauth          # browser flow → /var/lib/hermes/.hermes/auth.json
sudo systemctl restart hermes-agent
./deploy hermes doctor
```

Talk: `./deploy hermes chat`, Telegram (allowlisted), or `https://archimedes.<domain>/`.

Identity: leave `SOUL.md` absent or agent-written.

## 2. GBrain one-shot

Nix already starts `gbrain-mcp-http` and the two plugins. Still needed once:

```bash
./deploy gbrain-setup              # bun CLI, PGLite, bearer, import/embed
./deploy validate-gbrain
```

Scripts come from the locked **hermes-pnp** input (`scripts/gbrain-setup.sh`).
Agent-assisted: `./deploy hermes chat` with hermes-pnp `scripts/gbrain-bootstrap-query.txt`.

Never: `gbrain autopilot --install`; a second serve.

## 3. Day-2

| Action | How |
|--------|-----|
| Durable write / recall | MCP `put_page` / `query` / `get_page` |
| Hygiene | MCP or Hermes cron via MCP — never shell `gbrain` while up |
| Rotate ZeroEntropy | decrypt → edit → encrypt → remote-switch → restart hermes-agent |
| Soft reset, keep brain | `./deploy clean-hermes-state` |

PGLite “WASM Aborted”: stop stack, pkill orphans, restart `gbrain-mcp-http`. See hermes-pnp `docs/gbrain.md`.

## 4. Paths

| Concern | Host | Container |
|---------|------|-----------|
| Default workspace | `/var/lib/hermes` | `/data` |
| Hermes home | `/var/lib/hermes/.hermes` | `/data/.hermes` |
| Skills (extraSkills) | `/var/lib/hermes/skills` | `/data/skills` |
| GBrain home | `/var/lib/hermes/home/.gbrain` | `/home/hermes/.gbrain` |
| Brain git | `/var/lib/hermes/home/brain` | `/home/hermes/brain` |
| bun / gbrain | `…/home/.bun` | `/home/hermes/.bun/bin` |
| Jail identity | `/var/lib/hermes-oci/<name>` | (root 0700) |

## 5. Browser (CDP + agent-browser gate)

`hermesPnP.browser` — Brave, profile `/var/lib/hermes/browser-profile`, CDP `:9222`, gate `:4848` via Caddy `https://browser.<domain>/` (LAN/Tailscale only, no tunnel).

```bash
hermes-browser-status
sudo -u hermes hermes-browser-import-cookies /var/lib/hermes/browser-cookies/ra-axs.json
```

Phone captcha: agent sends `HERMES_BROWSER_GATE_URL` (Tailscale/LAN).

## 6. WebUI

`127.0.0.1:8787` → Caddy + tunnel `archimedes.<domain>`. After a hostname change, re-run `./scripts/setup-cloudflare-tunnel.sh`.

```bash
curl -sS http://127.0.0.1:8787/health
sudo systemctl restart hermes-agent hermes-webui
```
