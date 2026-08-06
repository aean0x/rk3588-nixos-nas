---
name: retrieval-reflex
description: "When brain pointers appear or a durable entity is salient, get_page / volunteer_context before answering from MEMORY alone."
---

# Retrieval reflex (gbrain-native)

Policy skill for gbrain push-based context
(`docs/guides/push-context.md`, #2095 / resolve-ipc).

## What injects pointers

| Channel | Who | How |
|---------|-----|-----|
| Ambient | plugin `gbrain-retrieval-reflex` | Entity extract → **unix resolve IPC** owned by live `gbrain serve` → injects `## Brain pages…` |
| Op | **you** (MCP) | `volunteer_context` with a rolling `user:` / `assistant:` window |
| Search | **you** (MCP) | `query` / `get_page` |

There is **no** static `gbrain-pointer-index.json` and **no** `gbrain-reflex` alias table.

## When a pointer block appears

1. Treat it as a hint that pages **exist**, not as full truth.
2. Call MCP **`get_page`** on slugs that are the subject of the answer.
3. Do **not** invent details from MEMORY when a pointer is present.

## When no pointer block (or IPC down)

1. Call MCP **`volunteer_context`** with a short window (oldest → newest,
   `user:` / `assistant:` lines; current user turn is enough for one-shot).
2. Else **`query`** with a tight phrase.
3. Session / MEMORY only after that; durable facts → **`put_page`**.

## Anti-patterns

- Shell `gbrain` CLI while hermes-agent is up
- Maintaining a workspace alias JSON
- Answering from MEMORY alone when a pointer or durable entity is the subject

## Tools (typical MCP names)

| Intent | Tool |
|--------|------|
| Multi-turn push | `volunteer_context` |
| Open page | `get_page` |
| Search | `query` |
| Write | `put_page` |
