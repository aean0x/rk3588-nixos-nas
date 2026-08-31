# BankSync via hermesPnP.mcpProxy (enable is in default.nix).
# Host injects X-API-Key; Hermes only sees the loopback proxy URL.
# userAgent: mcp.banksync.io is Cloudflare-fronted and returns 403 Error
# 1010 for Python-client signatures (python-httpx / Python-urllib); the
# Hermes MCP SDK sends python-httpx by default. A neutral proxy UA passes.
{
  config,
  ...
}:
{
  services.hermesPnP.mcpProxy.backends.banksync = {
    upstream = "https://mcp.banksync.io";
    userAgent = "mcp-proxy/1";
    secrets."X-API-Key".file = config.sops.secrets.banksync_api_key.path;
  };

  services.hermes-agent.mcpServers.banksync = {
    url = "http://127.0.0.1:3140/banksync";
    timeout = 180;
  };
}
