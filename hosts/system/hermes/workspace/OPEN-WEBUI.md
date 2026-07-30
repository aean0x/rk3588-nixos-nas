# Open WebUI ↔ Hermes (rocknas)

Polished web chat frontend for Hermes Agent via the built-in OpenAI-compatible API.

## Architecture

```
Browser → https://open-webui.<domain>   (Caddy, LAN-only by default)
       → services.open-webui            127.0.0.1:8080
       → Hermes API server              http://127.0.0.1:8642/v1
       → full agent tools on rocknas
```

- **API stays on loopback** (`API_SERVER_HOST=127.0.0.1`). Never bind `0.0.0.0` publicly.
- Only Open WebUI (via Caddy) faces LAN/Tailscale — same pattern as `hermes.<domain>` dashboard.
- Port **8080** is intentional (AdGuard uses :3000, FileBrowser :8085, dashboard :9119).

## URL and first login

| Item | Value |
|------|--------|
| URL | `https://open-webui.<domain>` (e.g. `https://open-webui.aean.io`) |
| Auth | `WEBUI_AUTH=true` — **first user becomes admin** |
| Model dropdown | Should list **`hermes-agent`** (`API_SERVER_MODEL_NAME`) |
| API type | **Chat Completions** (default, supported). Responses mode is experimental. |

## Secrets (operator)

Shared sops key `hermes_api_server_key`:

| Path | Env var |
|------|---------|
| `/run/hermes.env` | `API_SERVER_KEY` (+ static `API_SERVER_*`) |
| `/run/open-webui.env` | `OPENAI_API_KEY` |

This is the **HERMES_MANAGED** durable path (sops → environmentFiles → `.env` merge). Do **not** use `hermes config set API_SERVER_*` for production — Nix will reassert on activation/restart.

```bash
cd secrets && ./decrypt
# edit secrets.yaml.work:
#   hermes_api_server_key: "$(openssl rand -hex 32)"
./encrypt
# then remote-test / remote-switch and:
sudo systemctl restart hermes-agent open-webui
```

## Health checks (on device)

```bash
# Gateway API up
curl -sS http://127.0.0.1:8642/health
# expect: {"status":"ok", ...}

# Models (use the real key; do not paste into chat logs)
KEY=$(grep '^API_SERVER_KEY=' /run/hermes.env | cut -d= -f2-)
curl -sS -H "Authorization: Bearer $KEY" http://127.0.0.1:8642/v1/models
# expect data[].id hermes-agent

# Open WebUI listening loopback only
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
ss -ltn | grep -E ':8080|:8642'

# Services
systemctl status hermes-agent open-webui --no-pager
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `/health` fails | `systemctl restart hermes-agent`; confirm `API_SERVER_ENABLED=true` in `/run/hermes.env` and container env |
| `/v1/models` → 401 | Key mismatch: Open WebUI `OPENAI_API_KEY` must equal Hermes `API_SERVER_KEY` |
| Empty / wrong models | Confirm URL ends with `/v1`; disable Ollama clutter (`ENABLE_OLLAMA_API=false`) |
| Env change ignored after first UI launch | Open WebUI **persists** connections in its DB — Admin → Connections, or reset state under `/var/lib/open-webui` |
| Long first boot | Open WebUI downloads embedding models (~150MB) once |
| Tools run on NAS | Expected — API server is a full Hermes runtime on rocknas, not a pure LLM proxy |

### Known upstream quirks

- **Chat Completions** is the supported default path for Open WebUI ↔ Hermes.
- **Responses** mode (experimental): better structured tool-call SSE in theory; Open WebUI still often sends full history client-side; tool UX can differ.
- Long multi-tool sessions can feel slow (agent is working); progress tokens may stream as tool indicators before the final answer.

## Out of scope

- `hermes-webui` (nesquena) — not used; this stack is Open WebUI only.
- Exposing `:8642` on WAN.
- Enabling Ollama by default.
