---
name: retrieval-reflex
description: "Use when a named entity/brain pointer is salient — open GBrain page before answering from MEMORY."
---

# Retrieval reflex (GBrain)

**When a named entity or injected GBrain pointer is the subject of the turn, open the page before answering from MEMORY.md or session alone.**

This skill is policy only. Infra injects compact pointers via the `gbrain-reflex` plugin (`pre_llm_call`); you still decide when to retrieve full content.

## When to retrieve

Open a page (or run a query) when **any** of these hold:

1. **Pointer present** — the turn includes a `## GBrain pointers` block (or you already know a stable slug).
2. **Named durable entity** — people, integrations, ops maps, project SoT, taste guides, host identity.
3. **Preference / history question** — “what do we know about X”, “how do we usually…”, prior decisions.
4. **About to invent process** — if the answer should live in GBrain, check first.

**Skip** logistics-only turns (acks, pings, pure yes/no) and pure ephemeral chat with no durable subject.

## Retrieval ladder (cheap → deep)

1. **Pointer / known slug** → `mcp__gbrain__get_page` (or equivalent `get_page` tool) with that slug.
2. **No pointer but clear topic** → `mcp__gbrain__query` / `mcp__gbrain__volunteer_context` with a tight query.
3. **Follow links** — if the page links related ops maps, open only what the answer needs (do not dump the graph).
4. **Still missing** — answer from session/MEMORY only after the above; if the fact is durable, `put_page` when you learn it.

Prefer **MCP tools while `gbrain serve` is up**. Never use the `gbrain` CLI in-session (PGLite single-writer; host timers own batch CLI).

## Tool names

Hermes MCP tools are typically:

| Intent | Tool (typical) |
|--------|----------------|
| Open page by slug | `mcp__gbrain__get_page` |
| Search / recall | `mcp__gbrain__query` |
| Suggest relevant context | `mcp__gbrain__volunteer_context` |
| Durable write | `mcp__gbrain__put_page` |

If tool_search hides them, search for `gbrain` and call the resolved name. Do **not** require an OpenClaw resolver or any second memory product.

## Anti-patterns

- Seeing a pointer and answering only from MEMORY.md
- Dumping full page bodies into chat when a short cite + answer suffices
- Re-implementing alias matching (infra owns the index + injection)
- CLI `gbrain get` / `put` while the gateway is running
- Treating this skill as optional polish when the subject is a known ops/person/taste entity

## Relationship to infra

| Layer | Owner |
|-------|--------|
| Alias index JSON (`gbrain-pointer-index.json`) | **You** (Hermes) — edit aliases/slugs; Nix seeds once only |
| `pre_llm_call` injection code | Flake / `gbrain-reflex` plugin (infra) |
| Open page / query / put when salient | **You** (this skill) |
| This skill file | **You** after seed — Nix does not overwrite |
| Nightly consolidate / embed / dream | Host timers |

Pointers are one-line synopses only — full truth lives on the page (`ops/gbrain-protocol`).
