# GBrain + Hermes (canonical)

GBrain is the long-term knowledge store. Hermes MEMORY.md is short working notes only.

## Day-to-day (gateway up)

Use **MCP tools only** (`mcp__gbrain__*`):

- `get_page` / `query` / `volunteer_context` — recall
- `put_page` — durable write (stable slugs: `ops/…`, `people/…`, `projects/…`, `taste/…`)
- `add_link` when relating pages

Never run `gbrain` CLI while the gateway is up (PGLite single-writer). Exclusive CLI is host-timer only and stops the agent first.

## MEMORY.md budget

- Injection budget ~2200 chars. Near-full is **not** a missing wipe job.
- Durable facts → `put_page`, then replace MEMORY lines with short GBrain pointers.
- Ephemeral/task progress → never MEMORY.
- Plugin `gbrain-memory-flush` injects a pre_llm nudge when MEMORY ≥ ~1600 chars.

## Background self-improvement

Hermes `background_review` (post-turn) can write MEMORY/skills only — **no MCP** (prefix-cache parity, `_skip_mcp_refresh`). It must not become a second GBrain writer. Durable promotion happens on the **main** turn via MCP + the memory-flush nudge.

## Host timers (exclusive CLI)

| Unit | Role |
|------|------|
| `hermes-gbrain-consolidate.timer` | Snapshot MEMORY (audit); import `~/brain` md; dream. **No** default MEMORY→inbox dump. |
| `gbrain-embed.timer` | Embed refresh |
| `gbrain-dream` | Via consolidate chain |

Emergency MEMORY inbox dump only if `GBRAIN_MEMORY_INBOX_DUMP=1` on the consolidate service.

## Pointer injection

Plugin `gbrain-reflex` injects up to 3 compact pointers from `gbrain-pointer-index.json`. Open pages with MCP when the subject is salient (`retrieval-reflex` skill).

## Context management

HMC + native Hermes compression run automatically. Do not hand-roll context pruning mid-task.
