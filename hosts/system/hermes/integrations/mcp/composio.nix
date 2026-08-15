# Composio Connect via the local MCP proxy.
# Hermes talks to loopback; the proxy injects COMPOSIO_API_KEY and applies
# toolkit filters. Upstream: https://connect.composio.dev/mcp
{
  config,
  ...
}:
let
  proxy = config.services.mcpProxy;
  gmailExcludeLabel = "old-inboxes-ian.searvo@gmail.com";
in
{
  services.mcpProxy = {
    enable = true;
    backends.composio = {
      upstream = "https://connect.composio.dev/mcp";
      secrets.Authorization = {
        file = config.sops.secrets.composio_api_key.path;
        prefix = "Bearer ";
      };
      unwrap = [
        {
          tool = "COMPOSIO_MULTI_EXECUTE_TOOL";
          each = "tools";
          name = "tool_slug";
          args = "arguments";
        }
      ];
      toolkits.gmail = {
        # Only tools that take a Gmail `query` string. A prefix match would
        # inject query= onto GMAIL_LIST_LABELS / fetch-by-id and change them.
        match.names = [
          "GMAIL_FETCH_EMAILS"
          "GMAIL_LIST_THREADS"
        ];
        args.query = {
          requireTokens = [ "-label:${gmailExcludeLabel}" ];
          denyTokens = [ "label:${gmailExcludeLabel}" ];
        };
      };
    };
  };

  services.hermes-agent.mcpServers.composio = {
    url = "http://${proxy.listenAddress}:${toString proxy.listenPort}/composio";
    connect_timeout = 400;
    timeout = 180;
  };

  systemd.services.hermes-agent = {
    after = [ "mcp-proxy.service" ];
    wants = [ "mcp-proxy.service" ];
  };
  systemd.services.hermes-webui = {
    after = [ "mcp-proxy.service" ];
    wants = [ "mcp-proxy.service" ];
  };
}
