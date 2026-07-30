# GBrain — how Feng should use long-term memory

**Read this at session start.** Declarative infra owns timers/MCP; **you** own write/recall discipline.

## Split of ownership

| Layer | Owner | What goes here |
|-------|--------|----------------|
| Hermes `MEMORY.md` | Agent (memory tool) | Working notes only: open tasks this week, ephemeral ops crumbs |
| Session / `session_search` | Hermes runtime | Recent chat; not durable SoT |
| **GBrain pages** (MCP) | Agent + nightly consolidate | Durable knowledge: preferences, maps, project facts, playbooks |
| `~/brain` markdown | Agent / git | Federated source; `gbrain sync` imports into pages |
| Inbox `export/inbox/*.json` | consolidate timer | Hermes→brain batch; you rarely write JSON by hand |

## Hard rules (every turn)

1. **Recall first:** for history, preferences, “what do we know about X”, run GBrain MCP `query` / `volunteer_context` **before** relying on MEMORY.md.
2. **Durable write:** anything that should still matter next month → MCP `put_page` (or update page). Do **not** park it only in MEMORY.md.
3. **Prefer MCP while serve is up.** Never `gbrain put`/`list`/`dream` CLI in-session — CLI fights PGLite with MCP serve. Host timers use exclusive CLI for batch only.
4. **MEMORY.md slim:** if MEMORY grows with ops maps (Maton, workstation, PR process), **promote** to a GBrain page and leave a one-line pointer in MEMORY.
5. **Graph when useful:** related pages → `link`; time-bound events → timeline tools. Empty graph is a process failure, not “optional polish”.

## What infra already does (do not reimplement)

- MCP: `gbrain serve` (tools as `mcp_gbrain_*`, may be behind tool_search)
- Daily: `hermes-gbrain-consolidate` → snapshot MEMORY, import inbox, dream (+ `~/brain` sync)
- Weekly: `gbrain-embed` → `embed --stale`
- Nightly: `gbrain-dream`

If inbox is stuck, tell the operator to run `sudo hermes-gbrain-consolidate` (exclusive path freezes MCP serve briefly).

## First pages to seed (if missing)

- `ops/maton-map` — Maton/email/calendar integration map  
- `ops/workstation` — nix-pc SSH / agent rules  
- `ops/feng-autonomy` — L2/L3/L4 summary pointer  
- `projects/*` — active project SoT  

Use MCP put_page; keep MEMORY as index only.

## Proactive pointers (infra)

Infra owns auto-recall **pointers only** — not a second memory product.

- **`gbrain-reflex` plugin** (`pre_llm_call`) injects **0–3** compact pointers into the **user message** from a static alias index (`gbrain-pointer-index.json`). This preserves the system-prompt cache (Hermes invariant: never inject into system prompt).
- Pointers look like: `Name → slug — one-line synopsis`. Full pages are **never** auto-dumped.
- When a pointer (or named entity) is the **subject** of the turn, open it with MCP `get_page` / `query` / `volunteer_context` — see skill **`retrieval-reflex`**.
- Fail-open: no network, no `gbrain` CLI in the hot path (PGLite locked by MCP serve). Index is flake-owned under `workspace/gbrain-pointer-index.json`; update it when adding durable slugs that should auto-surface.
- Env: `GBRAIN_POINTER_INDEX` (default container path `/data/workspace/gbrain-pointer-index.json`).

## Anti-patterns

- Defaulting to MEMORY + session_search for every recall  
- Never calling `volunteer_context`  
- CLI `gbrain put` while gateway is up  
- Treating probe/benchmark pages as a healthy brain  
- Ignoring injected `## GBrain pointers` when the entity is the subject  

