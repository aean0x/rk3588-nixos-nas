# Hermes WebUI ↔ Hermes Agent (rocknas)

Full-parity browser UI for Hermes Agent ([nesquena/hermes-webui](https://github.com/nesquena/hermes-webui)).
Runs the agent **in-process** against `HERMES_HOME` (not OpenAI API passthrough).

## Architecture

```
WAN:  Browser → CF edge → cloudflared → hermes-webui :8787 → HERMES_HOME agent
LAN:  Browser → Caddy archimedes.<domain> → hermes-webui :8787 → HERMES_HOME agent
```

Same agent package and store-safe env as the gateway (`overrides/package-fix.nix` + `runtime.nix`). WebUI does not re-override extras. Official `hermes dashboard` is removed.

Declared in `hermes-webui.nix`:

```nix
services.caddy.proxyServices."archimedes.${domain}" = 8787;
services.cloudflareTunnel.proxyServices."archimedes.${domain}" = 8787;
```

- **Bind loopback only** (`HERMES_WEBUI_HOST=127.0.0.1`). Never open the firewall for :8787.
- **CGNAT:** public path is tunnel only (`./scripts/setup-cloudflare-tunnel.sh` once / after hostname changes).
- Port **8787** (WebUI default); state under `/var/lib/hermes-webui`; runs as `hermes:hermes`.
- Same 2 GiB / 2 CPU / OOM +500 cap as the gateway (`runtime.nix`).
- Optional loopback API server still on **:8642** for scripts/tools (not used by WebUI chat).
- **Model Router extension:** `HERMES_WEBUI_EXTENSION_DIR` → flake `integrations/plugins/model-router/webui` (store path). Injects `/auto` `/t1` `/t2` `/t3` composer buttons and overlays the model chip (`Auto · T1 · deepseek-v4-flash`). No WebUI source patches.

## URL

| Item | Value |
|------|--------|
| URL | `https://archimedes.<domain>` (e.g. `https://archimedes.aean.io`) |
| Auth | Optional `HERMES_WEBUI_PASSWORD` (set in Settings or sops if exposing further) |
| Chat | In-process Hermes agent (same config as CLI / gateway) |
| TTS | ElevenLabs when `ELEVENLABS_API_KEY` is set; flake SoT: `tts.provider=elevenlabs` + `eleven_flash_v2_5` + voice `pNInz6obpgDQGcFmaJgB` |

## Secrets (operator)

| Path | Env var |
|------|---------|
| `/run/hermes.env` | Full agent secrets including `ELEVENLABS_API_KEY`, `API_SERVER_KEY`, BRAVE/XAI/FIRECRAWL |

```bash
cd secrets && ./decrypt
# edit secrets.yaml.work:
#   elevenlabs_api_key: "sk_..."
./encrypt
# then remote-test / remote-switch and:
sudo systemctl restart hermes-agent hermes-webui
```

## Health checks (on device)

```bash
curl -sS http://127.0.0.1:8787/health
# expect: ok / healthy JSON

ss -ltn | grep -E ':8787|:8642'
systemctl status hermes-agent hermes-webui --no-pager

# ElevenLabs present (do not paste values into chat logs)
sudo grep -q '^ELEVENLABS_API_KEY=.' /run/hermes.env && echo elevenlabs_env_ok
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `/health` fails | `systemctl restart hermes-webui`; check journal for HERMES_HOME / python path |
| Chat fails / missing models | Confirm `hermesHome` = `/var/lib/hermes/.hermes` and service user is `hermes` |
| ElevenLabs TTS 503 | Ensure `ELEVENLABS_API_KEY` in `/run/hermes.env` and restart `hermes-webui` |
| Tunnel 502 | `systemctl status cloudflared`; confirm `proxyServices."archimedes…"` = 8787 |
| Old open-webui still answering | Unit removed; stop leftover if any: `systemctl stop open-webui` then rebuild |

## Out of scope / retired

- **Open WebUI** (`services.open-webui`, `open-webui.<domain>`) — decommissioned in favor of Hermes WebUI.
- Exposing `:8787` or `:8642` on WAN without tunnel.
