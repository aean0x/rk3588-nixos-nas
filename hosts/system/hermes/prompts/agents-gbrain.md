# AGENTS.md — GBrain (long-term memory)

gbrain is the default long-term memory for this deployment.

## Trigger rules

- User shares a file, link, note, transcript, article, meeting, research, or idea → evaluate for gbrain import
- User asks what we know, background, history, relationships, or context on a person/company/topic → check gbrain first
- User wants something remembered, organized, or retrievable long-term → route to gbrain
- Content involves people, companies, facts, decisions, timelines, or structured knowledge → strong gbrain candidate

## Implementation

- **MCP only:** `gbrain serve` (declarative `services.hermes-agent.mcpServers.gbrain`)
- Tools: `put_page` / `query` / `get_page` / **`volunteer_context`** (via tool_search as needed)
- Ambient pointers: plugin `gbrain-retrieval-reflex` (gbrain resolve IPC — not a static index)
- Brain git repo: `~/brain` (container: `/home/hermes/brain`) — optional mirror; write via MCP
- **Never shell `gbrain` CLI** while the agent is up (PGLite single-writer)
- Maintenance: gbrain MCP surfaces or Hermes cron **via MCP tools only**
- Do not require the user to mention gbrain explicitly on knowledge work
