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
| Hermes memory snapshot + inbox | `hermes-gbrain-consolidate.timer` | yes |
| G-Brain import inbox + dream | same service chain | yes |
| G-Brain embed refresh | `gbrain-embed.timer` | yes |
| Hermes curator (skills) | gateway `curator.interval_hours` | yes |

Manual: `/run/current-system/sw/bin/hermes-gbrain-consolidate` on the host (runs in container as `hermes`).

## 5. Anti-clobber

1. **`.hermes-write.lock`** — Hermes writers should hold during MEMORY.md updates.
2. **`.consolidation.lock`** — only one consolidation run at a time; others log `skipped` and exit 0.
3. **Snapshots** — new UTC directory per run; never overwrite prior snapshot contents.
4. **G-Brain** — must not edit `MEMORY.md` / `USER.md`; ingest only from `export/inbox` or snapshot copies.
5. **Dedup:** inbox records carry `record_id`; gbrain pages use frontmatter `hermes_record_id` — never blind overwrite newer content.

## 6. Export record schema

All inbox JSON must validate against `export-schema.json` (required: `record_id`, `created_at`, `source_agent`, `source_session`, `namespace`, `kind`, `body`, `attribution`, `schema_version`).

## 7. G-Brain trigger rules

- User shares durable knowledge → evaluate gbrain import (MCP + inbox export).
- Recall / background / history questions → gbrain `query` / MCP first.
- MCP: `gbrain serve` (declarative). CLI: `~/.bun/bin/gbrain`. Brain git: `~/brain`.