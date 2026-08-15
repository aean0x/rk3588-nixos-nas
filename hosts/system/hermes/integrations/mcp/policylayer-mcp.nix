# Composio Connect MCP (HTTP + OAuth).
# Official: https://connect.composio.dev/mcp
# COMPOSIO_API_KEY stays in /run/hermes.env for API use; MCP auth is OAuth.
{
  services.hermes-agent.mcpServers.composio = {
    url = "https://api.policylayer.com/mcp";
    connect_timeout = 400;
    timeout = 180;
  };
}
