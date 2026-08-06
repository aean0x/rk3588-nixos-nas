# AGENTS.md — Memory manifest (look here first)

**On every process init** (Hermes gateway, CLI, G-Brain `serve`), load this file and the machine registry before any memory action. Cached copies are invalid; the registry on disk wins.

## 1. Authoritative registry

| Artifact | Host path | Container path |
|----------|-----------|----------------|
| This manifest | `/var/lib/hermes/.hermes/AGENTS.md` | `/data/.hermes/AGENTS.md` |
| Location registry (JSON) | `/var/lib/hermes/memory/registry.json` | `/data/memory/registry.json` |
| Export JSON schema | `/var/lib/hermes/memory/export-schema.json` | `/data/memory/export-schema.json` |

Environment override (optional): `HERMES_MEMORY_REGISTRY` must point at the registry JSON if paths are relocated.

**No implicit discovery.** Do not scan `$HOME`, `/tmp`, or package defaults for Hermes artifacts.

## 2. Storage layout

**Hermes (episodic + profile)**

- `memories/MEMORY.md` — working / short-horizon only (Hermes memory tool)
- `memories/USER.md` — operator profile
- `memories/export/inbox/` — optional JSON records (schema v1)
- `memories/export/snapshots/<UTC>/` — optional audit snapshots
- `state.db` + `sessions/` — session index

**G-Brain (long-term)**

- `~/.gbrain/brain.pglite` — vector + page store (PGLite)
- `~/brain` — optional git mirror / federated source
- `~/.gbrain/audit/` — structured audit JSONL (if used)

## 3. Namespace and retention

- **Namespace:** `default` — single principal `hermes`. Cross-user reads/writes are forbidden.
- **Hermes curator:** skills lifecycle per `config.yaml` `curator.*` (gateway-driven).
- **G-Brain:** long-term knowledge via MCP only while the agent is up.

## 4. Entry points

| Job | Trigger | Notes |
|-----|---------|-------|
| Durable write / recall | MCP `put_page` / `query` / `get_page` | **Only** agent path |
| Ambient pointers | plugin `gbrain-retrieval-reflex` | resolve IPC → live serve |
| MEMORY pressure | plugin `gbrain-memory-flush` | nudge → MCP put_page |
| Hermes curator (skills) | gateway `curator.interval_hours` | yes |
| Multi-turn push / hygiene | MCP `volunteer_context` / Hermes cron **via MCP** | never shell `gbrain` |

**Day-to-day durable writes:** MCP `put_page` while gateway is up.  
**No host exclusive CLI** (consolidate / dream / embed / nightly wrappers removed).

## 5. Anti-clobber

1. **`.hermes-write.lock`** — Hermes writers should hold during MEMORY.md updates.
2. **G-Brain** — must not edit `MEMORY.md` / `USER.md` from outside Hermes memory tools.
3. **PGLite single-writer:** only `gbrain serve` (MCP) while hermes-agent is up. Never second CLI process.

## 6. Export record schema

All inbox JSON must validate against `export-schema.json` (required: `record_id`, `created_at`, `source_agent`, `source_session`, `namespace`, `kind`, `body`, `attribution`, `schema_version`).

## 7. G-Brain trigger rules (agent discipline)

**MEMORY.md is working memory, not the long-term brain.** Durable knowledge lives in GBrain pages.

| Situation | Do this |
|-----------|---------|
| Recall / history / “what do we know” | MCP `query` / `volunteer_context` **before** MEMORY.md |
| User shares durable knowledge | MCP `put_page`; not MEMORY-only |
| Ops maps, preferences, project SoT | GBrain pages under stable slugs (`ops/…`, `projects/…`) |
| Proactive pointers (injected brain pages block) | Infra: `gbrain-retrieval-reflex` (resolve IPC); **open** via MCP `get_page` (`retrieval-reflex` skill) |
| Multi-turn / no pointer | MCP `volunteer_context` then `get_page` / `query` |
| Batch hygiene / onboard | MCP ops on live serve, or Hermes cron **calling MCP only** — **never** shell `gbrain` |

### PGLite single-writer (infra)

- MCP `gbrain serve` holds PGLite exclusively while the gateway is up.
- Concurrent CLI fails with “database already open” / WASM init abort — **prevention over reinit**.
- **No** host exclusive runner, timers, or agent-visible `gbrain-exclusive-cli`.
- Maintenance: gbrain’s MCP/onboard surfaces and future cooperative serve scheduling (upstream #677). Do not reinvent stop-agent → CLI → restart.

### Surfaces

- MCP: `gbrain serve` — **only** agent path for brain I/O
- CLI: bootstrap / disaster recovery **with agent stopped** (operator only)
- Protocol SoT: GBrain page `ops/gbrain-protocol` (MCP). Host operator ref: repo `reference/GBRAIN.md` (not in live workspace).

### Config vs agent

| Config / Nix owns | Hermes owns |
|-------------------|-------------|
| MCP serve declaration, plugin **code**, memory registry install | Brain pages, pointer index content, SOUL, cron prompts |
| Force-disable of legacy exclusive timers | GBrain CLI version (`bun install -g`), `gbrain config` |
