# GBrain + Hermes (workspace stub)

**Canonical SoT:** GBrain page `ops/gbrain-protocol` (MCP `get_page`).  
This file is a **bootstrap seed only** — Hermes owns it after first install; Nix will not overwrite.

## Day-to-day (gateway up)

- MCP only: `get_page` / `query` / `put_page` / `add_link`
- Never exclusive `gbrain` CLI while hermes-agent is up (PGLite single-writer)
- MEMORY.md is thin working notes (~2200 chars); durable → `put_page` then pointer lines

## Hermes-owned (edit freely)

| Artifact | Path |
|----------|------|
| Pointer alias index | `workspace/gbrain-pointer-index.json` |
| This stub | `workspace/GBRAIN.md` |
| Retrieval skill | `skills/retrieval-reflex/SKILL.md` |
| Brain markdown | `~/brain/**` |
| GBrain CLI version | `bun install -g @gbrain/cli` (or `gbrain self-upgrade`) |
| `~/.gbrain/config.json` | sources, embed model (not Nix) |

## Nix-owned (do not fight)

MCP `gbrain serve`, consolidate/embed/dream timers, memory registry + `AGENTS.md` install, HMC + gbrain plugins **code**.

## Sync vs import (host reality)

| Path | Works here? | Notes |
|------|-------------|--------|
| MCP `put_page` / `query` | **Yes** — preferred | While gateway up |
| `gbrain sync --source default` | **Yes** (exclusive + cwd) | Needs PGLite `sources.default.local_path` **and** CLI run with cwd under hermes HOME |
| Host shell `put` per `.md` | **Yes** | consolidate fallback if sync fails |
| `config.json` `sources.default.local_path` alone | Not enough | Runtime registry is PGLite `sources` table — pin via consolidate `ensure_default_source_path` or one-shot UPDATE |

### Host exclusive CLI gotcha (false “bun EACCES”)

Bun inherits the invoker’s **cwd** and `chdir`s into it before spawning git. If you run `sudo -u hermes gbrain …` from `/home/user` or `/root`, spawn fails with `EACCES` (looks like git broken). Always:

```bash
cd /var/lib/hermes/home   # or /home/hermes
sudo -u hermes env HOME=/var/lib/hermes/home PATH=… gbrain …
# host wrappers (hermes-gbrain-consolidate / embed / dream) already cd $HOME
```

## PGLite recovery (when WASM Aborted / MCP get_page dead)

1. **Markdown SoT first:** `~/brain` is source of truth. PGLite is rebuildable.
2. **Exclusive only:** `sudo systemctl stop hermes-agent` (releases serve lock).
3. Rotate bad DB: move `~/.gbrain/brain.pglite` → `brain.pglite.pre-reinit-<UTC>` (keep one recent bak; prune older `*.bak*` / `*.broken*` / `*.corrupt*` when space matters).
4. Reinit with same embed settings as config:
   ```bash
   # as hermes, HOME=/var/lib/hermes/home (host) or /home/hermes (container)
   gbrain reinit-pglite   # honor config: zeroentropyai:zembed-1 / 2560
   ```
5. Re-import markdown (not `sync`):
   ```bash
   # host: sudo hermes-gbrain-consolidate
   # or exclusive: for each ~/brain/**/*.md (skip hermes/inbox*): gbrain put <slug>
   ```
6. Embed: `gbrain embed --stale` (or host timer / `hermes-gbrain-embed`).
7. **Always restart serve before trusting MCP:** `systemctl start hermes-agent` — long-lived `gbrain serve` keeps a pre-reinit connection otherwise.
8. Verify exclusive then MCP: `gbrain list -n 20`, `hermes mcp list`, MCP `get_page ops/gbrain-protocol`, hybrid `query`.

### Diagnostics that mislead

- `gbrain doctor --fast` skips live PGLite — use full `gbrain doctor` exclusive.
- Bare `doctor`/`status` while serve holds the DB → “already open” / empty view, not necessarily dead data.
- After reinit, MCP may show 0 pages until serve restart + re-import.

## Reflex vs live MCP

- **gbrain-reflex** (static pointer index) injects aliases even if PGLite/MCP is down.
- **retrieval-reflex + MCP** is the live path; if MCP is dead, open pages fail until recovery above.
