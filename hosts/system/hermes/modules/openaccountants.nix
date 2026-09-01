# OpenAccountants MCP — open-source tax guides reviewed by named, licensed
# accountants. Hosted endpoint, no auth. Read-mostly surface (13 Read /
# 1 Write per PolicyLayer registry); grade D / identity unverified, no
# flagged tools — wired read-only per operator request.
{
  services.hermesPnP.mcpProxy.backends.openaccountants = {
    upstream = "https://www.openaccountants.com/api/mcp";
    # Neutral UA like banksync: some hosted MCP endpoints 403 the
    # python-httpx signature the Hermes MCP SDK sends by default.
    userAgent = "mcp-proxy/1";
  };

  services.hermes-agent.mcpServers.openaccountants = {
    url = "http://127.0.0.1:3140/openaccountants";
    timeout = 120;
  };
}
