# Hermes WebUI ↔ Hermes Agent (rocknas)

Full-parity browser UI for Hermes Agent ([nesquena/hermes-webui](https://github.com/nesquena/hermes-webui)).
Runs the agent **in-process** against `HERMES_HOME` (not OpenAI API passthrough).

## Architecture

```
WAN:  Browser → CF edge → cloudflared → hermes-webui :8787 → HERMES_HOME agent
LAN:  Browser → Caddy archimedes.<domain> → hermes-webui :8787 → HERMES_HOME agent
```

Declared in `hermes-webui.nix`:

```nix
services.caddy.proxyServices."archimedes.${domain}" = 8787;
services.cloudflareTunnel.proxyServices."archimedes.${domain}" = 8787;
```

- **Bind loopback only** (`HERMES_WEBUI_HOST=127.0.0.1`). Never open the firewall for :8787.
- **CGNAT:** public path is tunnel only (`./scripts/setup-cloudflare-tunnel.sh` once / after hostname changes).
- Hermes dashboard (`hermes.<domain>` :9119) remains LAN-only.
- Port **8787** (WebUI default); state under `/var/lib/hermes-webui`; runs as `hermes:hermes`.
- Optional loopback API server still on **:8642** for scripts/tools (not used by WebUI chat).

## URL

| Item | Value |
|------|--------|
| URL | `https://archimedes.<domain>` (e.g. `https://archimedes.aean.io`) |
| Auth | Optional `HERMES_WEBUI_PASSWORD` (set in Settings or sops if exposing further) |
| Chat | In-process Hermes agent (same config as CLI / gateway) |
| TTS | ElevenLabs when `ELEVENLABS_API_KEY` is set (engine selectable in Settings) |

## Secrets (operator)

| Path | Env var |
|------|---------|
| `/run/hermes.env` | `ELEVENLABS_API_KEY`, `API_SERVER_KEY`, … |
| `/run/hermes-webui.env` | `ELEVENLABS_API_KEY` |

```bash
cd secrets && ./decrypt
# edit secrets.yaml.work:
#   elevenlabs_api_key: "sk_..."
./encrypt
# then remote-test / remote-switch and:
sudo systemctl restart hermes-webui hermes-agent
```

## Health checks (on device)

```bash
curl -sS http://127.0.0.1:8787/health
# expect: ok / healthy JSON

ss -ltn | grep -E ':8787|:8642'
systemctl status hermes-agent hermes-webui --no-pager

# ElevenLabs present (do not paste values into chat logs)
sudo grep -q '^ELEVENLABS_API_KEY=.' /run/hermes-webui.env && echo elevenlabs_env_ok
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `/health` fails | `systemctl restart hermes-webui`; check journal for HERMES_HOME / python path |
| Chat fails / missing models | Confirm `hermesHome` = `/var/lib/hermes/.hermes` and service user is `hermes` |
| ElevenLabs TTS 503 | Ensure `ELEVENLABS_API_KEY` in `/run/hermes-webui.env` and restart `hermes-webui` |
| Tunnel 502 | `systemctl status cloudflared`; confirm `proxyServices."archimedes…"` = 8787 |
| Old open-webui still answering | Disable was declarative — `systemctl stop open-webui` / rebuild if a leftover unit exists |

## Out of scope / retired

- **Open WebUI** (`services.open-webui`, `open-webui.<domain>`) — decommissioned in favor of Hermes WebUI.
- Exposing `:8787` or `:8642` on WAN without tunnel.
