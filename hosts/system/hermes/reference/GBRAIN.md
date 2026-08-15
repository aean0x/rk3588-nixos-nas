# GBrain (operator reference)

**Canonical SoT:** GBrain page `ops/gbrain-protocol` (MCP `get_page`).  
Repo-only doc (not installed into live workspace). Hermes owns **brain pages**.

**Fresh-host setup:** `./deploy gbrain-setup` → `scripts/gbrain-setup.sh`  
**Agent bootstrap prompt:** `prompts/gbrain-bootstrap-query.txt`

## Rules

- **MCP via shared HTTP** to `http://127.0.0.1:3131/mcp` (tools: put_page / query / get_page / volunteer_context).
- **Never** spawn concurrent stdio `gbrain serve` (PGLite single-writer; hermes-agent#72887).
- **No** host exclusive CLI (consolidate/dream/embed removed).
- **No** static pointer index — ambient reflex uses resolve IPC on the HTTP serve.

## Day path

| Surface | Role |
|---------|------|
| systemd **`gbrain-mcp-http`** | Sole PGLite owner: `gbrain serve --http --bind 127.0.0.1 --port 3131` |
| Hermes MCP `gbrain` | **url** `http://127.0.0.1:3131/mcp` + **Bearer** header (gateway + WebUI + CLI) |
| Auth token (no sops) | Mint once: `gbrain auth create hermes-agents`. Store **literal** token in (1) `~/.gbrain/hermes-mcp.token` (2) `GBRAIN_REMOTE_TOKEN` in `~/.hermes/.env` (3) `config.yaml` `headers.Authorization: Bearer <token>`. **Never** `Bearer ${GBRAIN_REMOTE_TOKEN}` (no expansion → 401). Setup: `./deploy gbrain-setup` or skill `gbrain-http-auth`. |
| plugin `gbrain-retrieval-reflex` | Ambient: resolve IPC if sock present; else nudge MCP `volunteer_context` |
| MCP tools | put_page / query / get_page / volunteer_context |
| skill `retrieval-reflex` | Policy: open when pointers/salient |

**Why HTTP:** each Hermes agent process would otherwise stdio-spawn its own serve. WebUI + gateway = dual writers / lock orphans (hermes-agent#72887).

See gbrain `docs/mcp/DEPLOY.md`, `docs/guides/push-context.md`.

## Ops

```bash
# ./deploy catch-all splits args — quote ONE remote command:
./deploy 'sudo pkill -9 -f gbrain || true'
./deploy 'sudo systemctl restart gbrain-mcp-http hermes-agent'
./deploy 'systemctl is-active gbrain-mcp-http; ss -ltn | grep 3131; pgrep -a gbrain'

# Orphans / crash-loop (PGLite lock or WASM Aborted):
./deploy 'sudo systemctl stop hermes-webui hermes-agent gbrain-mcp-http'
./deploy 'sudo pkill -9 -f gbrain || true'
./deploy 'sudo rm -rf /var/lib/hermes/home/.gbrain/.locks /var/lib/hermes/home/.gbrain/brain.pglite/.gbrain-lock'
./deploy 'sudo systemctl reset-failed gbrain-mcp-http; sudo systemctl start gbrain-mcp-http'

# If still "PGLite failed to initialize" with no other gbrain process:
# data dir may be damaged — operator reinit (agent/HTTP stopped):
#   sudo -u hermes env HOME=/var/lib/hermes/home PATH=… gbrain reinit-pglite
# then reimport ~/brain, restart gbrain-mcp-http
```

## Maintenance

MCP ops on the live HTTP serve. Hermes cron via MCP only.  
Never `gbrain autopilot --install` as a second process on PGLite.

**Git durability:** `put_page` write-through only auto-commits when the brain
repo has been hardened (`gbrain sources harden default --pat-file ~/.gbrain/github.pat`).
That is CLI-only; stop `gbrain-mcp-http` first, run from `$HOME` as hermes
(Nixpkgs bun cannot spawn git if cwd is another user's home), then restart serve.
`./deploy gbrain-setup` includes this step.
