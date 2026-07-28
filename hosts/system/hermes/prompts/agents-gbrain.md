# AGENTS.md — GBrain (long-term memory)

gbrain is the default long-term memory for this deployment.

## Trigger rules

- User shares a file, link, note, transcript, article, meeting, research, or idea → evaluate for gbrain import
- User asks what we know, background, history, relationships, or context on a person/company/topic → check gbrain first
- User wants something remembered, organized, or retrievable long-term → route to gbrain
- Content involves people, companies, facts, decisions, timelines, or structured knowledge → strong gbrain candidate

## Implementation

- MCP server: `gbrain serve` (declarative in NixOS `services.hermes-agent.mcpServers.gbrain`)
- Brain git repo: `~/brain` (container: `/home/hermes/brain`)
- CLI: `gbrain` on PATH via `~/.bun/bin`
- Do not require the user to mention gbrain explicitly on knowledge work