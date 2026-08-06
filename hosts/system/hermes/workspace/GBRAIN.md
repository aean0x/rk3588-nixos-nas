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

MCP `gbrain serve`, consolidate/embed/dream timers + **shared exclusive runner**, memory registry + `AGENTS.md` install, HMC + gbrain plugins **code**, `gbrain-exclusive-cli` guard.

## PGLite single-writer (prevention first)

Markdown `~/brain` is **source of truth**. PGLite (`brain.pglite`) is rebuildable — prefer **never opening two writers** over reinit.

| Path | Who | Behavior |
|------|-----|----------|
| Day path | MCP `gbrain serve` | Holds PGLite while hermes-agent is up |
| Host jobs | `hermes-gbrain-exclusive` | flock → stop agent → wait (no serve / no `.gbrain-lock`) → payload → restart |
| Timers | consolidate / dream / embed | All go through exclusive; systemd `Conflicts=` so they cannot double-open |
| Ad-hoc CLI | `/var/lib/hermes/bin/gbrain-exclusive-cli` | **Refuses** if agent active or serve running; does not stop agent |
| Manual host | `sudo hermes-gbrain-consolidate` etc. | Same exclusive path as timers |

**Never:** bare `gbrain list|put|doctor|dream|embed` while serve is up. That is the multi-instance / WASM abort class.

### Missing MCP tools = crash-loop class

If config shows gbrain MCP **enabled** but sessions have **zero** gbrain tools (`get_page` / `put_page` missing):

1. Check `mcp-stderr` for `PGLite failed to initialize`, `WASM`, `module already instantiated`, `Aborted`.
2. That is almost always **single-writer violation** (or damaged DB after one) — serve process may still appear in `pgrep` while init fails every reconnect.
3. Soft recovery first: stop/start hermes-agent with **no concurrent CLI** (no host timer, no exclusive job).
4. Do **not** treat “process alive” as “tools registered”.

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
# host wrappers (hermes-gbrain-exclusive / consolidate / embed / dream) already cd $HOME
```

Or: stop agent, then `/var/lib/hermes/bin/gbrain-exclusive-cli doctor`.

## PGLite recovery (when WASM Aborted / MCP get_page dead)

**Prevention over reinit.** Only reinit if exclusive soft recovery fails and `gbrain doctor` (full) confirms damage.

1. **Markdown SoT first:** `~/brain` is source of truth. PGLite is rebuildable.
2. **No concurrent jobs:** `systemctl list-units 'hermes-gbrain*' 'gbrain-*'`; wait for exclusive flock free.
3. **Soft reset:** `sudo systemctl stop hermes-agent` → ensure no `gbrain serve` → clear stale `.gbrain-lock` only if no process holds it → `start hermes-agent` → watch mcp-stderr ≥2 min with no WASM spam.
4. **Exclusive doctor (read-only first):** stop agent, then  
   `gbrain-exclusive-cli doctor` or host exclusive `gbrain doctor` (not `--fast`).
5. Rotate bad DB only if doctor says damaged: move `~/.gbrain/brain.pglite` → `brain.pglite.pre-reinit-<UTC>`.
6. Reinit with same embed settings as config:
   ```bash
   # as hermes, HOME=/var/lib/hermes/home (host) or /home/hermes (container)
   gbrain reinit-pglite   # honor config: zeroentropyai:zembed-1 / 2560
   ```
7. Re-import markdown (not `sync` if broken):
   ```bash
   # host: sudo hermes-gbrain-consolidate
   # or exclusive: for each ~/brain/**/*.md (skip hermes/inbox*): gbrain put <slug>
   ```
8. Embed: `gbrain embed --stale` (or host timer / `hermes-gbrain-embed`).
9. **Always restart serve before trusting MCP:** `systemctl start hermes-agent` — long-lived `gbrain serve` keeps a pre-reinit connection otherwise.
10. Verify exclusive then MCP: `gbrain list -n 20`, `hermes mcp list`, **new session** MCP `get_page ops/gbrain-protocol`, hybrid `query`.

**Infra never auto-reinits** PGLite from timers. WASM errors log a recovery hint only.

### Diagnostics that mislead

- **`gbrain doctor --fast` lies (skips live PGLite)** — use full `gbrain doctor` under exclusive only.
- Bare `doctor`/`status` while serve holds the DB → “already open” / empty view, not necessarily dead data.
- After reinit, MCP may show 0 pages until serve restart + re-import.
- Alive `watchdog` + `bun … gbrain serve` ≠ healthy tools; check mcp-stderr for crash-loop cadence.

## Reflex vs live MCP

- **gbrain-reflex** (static pointer index) injects aliases even if PGLite/MCP is down.
- **retrieval-reflex + MCP** is the live path; if MCP is dead, open pages fail until recovery above.
