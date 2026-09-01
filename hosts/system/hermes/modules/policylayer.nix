# PolicyLayer MCP registry — the vetting gate for MCP servers (skill
# policylayer-mcp). Free single-server lookups, no auth, no secrets.
# Tools: search_registry, check_mcp_server, check_tool (+ get_change_events,
# licence-gated). Direct HTTP client like gbrain; no proxy hop needed.
{
  services.hermes-agent.mcpServers.policylayer-mcp = {
    url = "https://api.policylayer.com/mcp";
    connect_timeout = 60;
    timeout = 120;
  };
}
