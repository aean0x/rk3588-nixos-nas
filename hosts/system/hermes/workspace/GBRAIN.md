# GBrain (host stub)

**Canonical SoT:** GBrain page `ops/gbrain-protocol` (MCP `get_page`).  
Infra policy (Nix reinstalls). Hermes owns **brain pages**, not host pointer JSON.

## Rules

- **MCP only while agent is up:** `put_page` / `query` / `get_page` / **`volunteer_context`**.
- **Never shell `gbrain` CLI** (PGLite single-writer).
- **No host exclusive CLI** (consolidate/dream/embed removed).
- **No static pointer index** — ambient reflex uses gbrain resolve IPC.

## Day path

| Surface | Role |
|---------|------|
| MCP `gbrain serve` | Sole PGLite owner; opens `.gbrain-resolve.sock` under `database_path` |
| plugin `gbrain-retrieval-reflex` | Ambient: extract candidates → resolve IPC → inject pointers |
| MCP `volunteer_context` | Multi-turn push when agent needs a window |
| MCP `get_page` / `query` | Open / search |
| skill `retrieval-reflex` | Policy: open pages when pointers/salient |

See gbrain `docs/guides/push-context.md` and `src/core/context/resolve-ipc.ts`.

## Maintenance

MCP ops on live serve (`run_onboard` when available). Hermes cron via MCP only.  
Never `gbrain autopilot --install` alongside serve on PGLite.  
Upstream cooperative serve: garrytan/gbrain#677.
