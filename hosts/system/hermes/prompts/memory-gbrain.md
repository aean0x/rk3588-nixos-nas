# Persistent memory — GBrain

**Authoritative layout and consolidation rules:** `AGENTS.md` (memory manifest) and `/var/lib/hermes/memory/registry.json`. Read those on init; this file is a short operator summary only.

GBrain is the primary long-term memory system. Use gbrain MCP tools first for knowledge import, recall, and structured facts.

## Trigger rules (high precedence)

- User shares file, link, note, transcript, article, meeting, research, or idea → evaluate for gbrain import
- User asks "what do we know", background, history, relationships, or context on a person/company/topic → check gbrain first
- User wants something remembered, organized, or retrievable long-term → route to gbrain
- Content involves people, companies, facts, decisions, timelines, or structured knowledge → strong gbrain candidate

Brain repository: `~/brain`. MCP: `gbrain serve`.