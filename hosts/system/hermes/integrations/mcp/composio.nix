# Composio Connect via the local MCP proxy.
# Hermes talks to loopback; the proxy injects COMPOSIO_API_KEY and applies
# mail-surface filters. Upstream: https://connect.composio.dev/mcp
#
# First-party Gmail filter (API cannot create it — missing gmail.settings.basic).
# Label agent-blocked (id Label_16) already exists.
# Gmail Settings → Filters → Create a new filter:
# Has the words:
# ("password reset" OR "reset your password" OR "reset password" OR "forgot your password" OR "verification code" OR "one-time code" OR "one-time password" OR "security code" OR "sign-in code" OR "login code" OR "magic link" OR "click to approve" OR "approve this" OR "new sign-in" OR "new login" OR "new device" OR "unusual activity" OR "sign in to")
# Doesn't have:
# ("confirm your email" OR "verify your email" OR "confirm your account" OR "verify your account")
# Then: Skip Inbox, Apply label agent-blocked. Do not mark as read.
#
# Outlook: folder agent-blocked + inbox rule "agent-blocked" already created
# (subjectContains those phrases, move + stop).
{
  config,
  inputs,
  ...
}:
{
  imports = [ inputs.mcp-proxy.nixosModules.default ];

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
        args = {
          query = {
            prepend = "(in:inbox OR in:sent OR in:drafts) ";
            requireTokens = [
              "-label:agent-blocked"
            ];
            denyTokens = [
              "label:agent-blocked"
              "in:anywhere"
              "in:spam"
              "in:trash"
              "in:all"
            ];
          };
          label_ids.unset = true;
          include_spam_trash.denyValues = [ true ];
        };
      };
      toolkits.outlook = {
        match.names = [ "OUTLOOK_QUERY_EMAILS" ];
        args.folder = {
          default = "inbox";
          # sentitems and drafts are intentionally not denied.
          denyValues = [
            "agent-blocked"
            "junkemail"
            "deleteditems"
            "archive"
            "outbox"
            "recoverableitemsdeletions"
            "conversationhistory"
          ];
        };
      };
    };
  };

  services.hermes-agent.mcpServers.composio = {
    url = "http://127.0.0.1:3140/composio";
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
