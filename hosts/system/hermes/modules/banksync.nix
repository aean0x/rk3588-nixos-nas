# BankSync via hermesPnP.mcpProxy (enable is in default.nix).
# Host injects X-API-Key; Hermes only sees the loopback proxy URL.
{
  config,
  ...
}:
{
  services.hermesPnP.mcpProxy.backends.banksync = {
    upstream = "https://mcp.banksync.io";
    secrets."X-API-Key".file = config.sops.secrets.banksync_api_key.path;
  };

  services.hermes-agent.mcpServers.banksync = {
    url = "http://127.0.0.1:3140/banksync";
    timeout = 180;
  };
}
