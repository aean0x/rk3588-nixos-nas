# Open WebUI — retired

Open WebUI has been decommissioned in favor of **Hermes WebUI**.

See **`HERMES-WEBUI.md`**.

| Was | Now |
|-----|-----|
| `open-webui.<domain>` :8080 | `archimedes.<domain>` :8787 |
| `services.open-webui` | `services.hermes-webui` (flake `hermes-webui`) |
| `OPENAI_API_KEY` + Hermes API :8642 | In-process agent + `ELEVENLABS_API_KEY` for TTS |
