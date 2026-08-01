# AGENTS.md — Memory manifest (look here first)

**On every process init** (Hermes gateway, CLI, G-Brain `serve` / `dream` / consolidation wrappers), load this file and the machine registry before any memory or consolidation action. Cached copies are invalid; the registry on disk wins.

## 1. Authoritative registry

| Artifact | Host path | Container path |
|----------|-----------|----------------|
| This manifest | `/var/lib/hermes/.hermes/AGENTS.md` | `/data/.hermes/AGENTS.md` |
| Location registry (JSON) | `/var/lib/hermes/memory/registry.json` | `/data/memory/registry.json` |
| Export JSON schema | `/var/lib/hermes/memory/export-schema.json` | `/data/memory/export-schema.json` |

Environment override (optional): `HERMES_MEMORY_REGISTRY` must point at the registry JSON if paths are relocated. G-Brain wrappers must log resolved paths at startup.

**No implicit discovery.** Do not scan `$HOME`, `/tmp`, or package defaults for Hermes artifacts.

## 2. Storage layout

**Hermes (episodic + profile)**

- `memories/MEMORY.md` — durable facts (Hermes memory tool)
- `memories/USER.md` — operator profile
- `memories/export/inbox/` — JSON records for G-Brain import (schema v1)
- `memories/export/snapshots/<UTC>/` — read-only copies for consolidation (checksum manifest inside)
- `state.db` + `sessions/` — session index (read-only for G-Brain)

**G-Brain (long-term)**

- `~/.gbrain/brain.pglite` — vector + page store (PGLite)
- `~/brain` — optional git mirror / federated source
- `~/.gbrain/audit/` — structured consolidation audit JSONL

## 3. Namespace and retention

- **Namespace:** `default` — single principal `hermes`. Cross-user reads/writes are forbidden.
- **Hermes curator:** skills lifecycle per `config.yaml` `curator.*` (gateway-driven).
- **Hermes → G-Brain handoff:** export plane only; retention of snapshots 90 days (operator may prune older snapshot dirs).
- **G-Brain:** maintenance via `gbrain dream` and `gbrain embed --stale`; locks under `~/.gbrain/autopilot.lock`.

## 4. Consolidation entry points

| Job | Trigger | Idempotent |
|-----|---------|------------|
| Hermes MEMORY snapshot (audit only) | `hermes-gbrain-consolidate.timer` | yes |
| Optional MEMORY inbox dump | same, only if `GBRAIN_MEMORY_INBOX_DUMP=1` | yes |
| G-Brain import ~/brain + dream | same service chain | yes |
| G-Brain embed refresh | `gbrain-embed.timer` | yes |
| Hermes curator (skills) | gateway `curator.interval_hours` | yes |
| MEMORY pressure nudge | plugin `gbrain-memory-flush` (pre_llm_call) | yes |

**Day-to-day durable writes:** MCP `put_page` while gateway is up — **not** exclusive CLI. The old whole-MEMORY→`hermes/inbox/*` dump is retired (PGLite race / corruption class).

Manual exclusive maintenance: `/run/current-system/sw/bin/hermes-gbrain-consolidate` on the host (stops agent briefly).

## 5. Anti-clobber

1. **`.hermes-write.lock`** — Hermes writers should hold during MEMORY.md updates.
2. **`.consolidation.lock`** — only one consolidation run at a time; others log `skipped` and exit 0.
3. **Snapshots** — new UTC directory per run; never overwrite prior snapshot contents.
4. **G-Brain** — must not edit `MEMORY.md` / `USER.md`; ingest only from `export/inbox` or snapshot copies.
5. **Dedup:** inbox records carry `record_id`; gbrain pages use frontmatter `hermes_record_id` — never blind overwrite newer content.

## 6. Export record schema

All inbox JSON must validate against `export-schema.json` (required: `record_id`, `created_at`, `source_agent`, `source_session`, `namespace`, `kind`, `body`, `attribution`, `schema_version`).

## 7. G-Brain trigger rules (agent discipline)

**MEMORY.md is working memory, not the long-term brain.** Durable knowledge lives in GBrain pages.

| Situation | Do this |
|-----------|---------|
| Recall / history / “what do we know” | MCP `query` / `volunteer_context` **before** MEMORY.md |
| User shares durable knowledge | MCP `put_page` (and optional inbox export); not MEMORY-only |
| Ops maps, preferences, project SoT | GBrain pages under stable slugs (`ops/…`, `projects/…`) |
| Proactive pointers (injected `## GBrain pointers`) | Infra: `gbrain-reflex` plugin; **open** via MCP `get_page` / `query` when subject is salient (`retrieval-reflex` skill) |
| Batch import / dream / embed | **Host timers only** — never ad-hoc CLI put while MCP serve is up |

### PGLite single-writer (infra)

- MCP `gbrain serve` holds PGLite exclusively while the gateway is up.
- Concurrent CLI fails with “database already open”.
- Host timers (`hermes-gbrain-consolidate`, `gbrain-dream`, `gbrain-embed`) **stop hermes-agent**, run host CLI as `hermes`, then **start** hermes again. No docker-exec race.
- Operator: `sudo hermes-gbrain-consolidate`

### Surfaces

- MCP: `gbrain serve` — **preferred for agent turns** (put_page / query)
- CLI: host maintenance only (timers above; exclusive — stops agent)
- Brain git: `~/brain` — agent commits; exclusive consolidate prefers `gbrain sync` then falls back to shell `put`
- Source path: PGLite `sources.default.local_path` must be `/home/hermes/brain` (config.json alone is not enough)
- Exclusive CLI: always cwd under hermes HOME (bun inherits invoker cwd; wrong cwd → false EACCES on git)
- Protocol: `/data/workspace/GBRAIN.md` (stub); SoT page `ops/gbrain-protocol`
- After any `reinit-pglite`: restart hermes-agent before trusting MCP; re-pin source path if status says no local_path

### Config vs agent

| Config / Nix owns | Hermes owns |
|-------------------|-------------|
| MCP serve, timers, exclusive CLI, registry, AGENTS.md install | put_page / query / links / timelines |
| Plugin code (gbrain-reflex, gbrain-memory-flush, HMC pin) | Pointer index JSON, retrieval-reflex skill, workspace GBRAIN.md stub |
| Embed/dream schedules | Brain content (`ops/gbrain-protocol` is memory SoT) |
| | MEMORY.md thin working set only — never durable SoT |

**Retired (do not reintroduce):** whole-MEMORY → `hermes/inbox/*` dumps; concurrent exclusive CLI while gateway is up; declarative SOUL.