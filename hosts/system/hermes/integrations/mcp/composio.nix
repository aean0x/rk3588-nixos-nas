# Composio via loopback mcp-proxy (auth injected; agent never sees the key).
# Live unit: mcp-proxy.service listens on 127.0.0.1:3140/composio and forwards
# to https://connect.composio.dev/mcp. This file is SoT for:
#   1. the Hermes MCP client URL
#   2. the mail-surface filter payload the proxy must load (backends.composio)
#
# First-party Gmail/Outlook rules move takeover / reset / approve / login-OTP
# mail into label+folder `agent-blocked`. Signup "confirm/verify your email"
# stays in inbox. The proxy then:
#   - injects -label:agent-blocked on Gmail query tools
#   - defaults Outlook QUERY_EMAILS to inbox; denies clutter/junk/archive/…
#     (sentitems + drafts remain passable by name)
#   - hides + denies filter/label/folder/rule admin, cross-folder search, and
#     fetch-by-id (ID oracle around the label)
# Existing archive: also keep denying label:old-inboxes-ian.searvo@gmail.com.
{
  lib,
  pkgs,
  ...
}:
let
  blockedLabel = "agent-blocked";
  oldInboxLabel = "old-inboxes-ian.searvo@gmail.com";

  gmailQueryGuard = {
    denyTokens = [
      "label:${oldInboxLabel}"
      "label:${blockedLabel}"
      "in:${blockedLabel}"
    ];
    requireTokens = [
      "-label:${oldInboxLabel}"
      "-label:${blockedLabel}"
    ];
  };

  # Well-known names only. Custom folder IDs stay undiscoverable because
  # OUTLOOK_LIST_MAIL_FOLDERS is denied. sentitems + drafts are not listed here.
  outlookFolderGuard = {
    default = "inbox";
    denyTokens = [
      blockedLabel
      "clutter"
      "junkemail"
      "deleteditems"
      "archive"
      "recoverableitemsdeletions"
      "outbox"
    ];
  };

  deniedMailTools = [
    "GMAIL_ADD_LABEL_TO_EMAIL"
    "GMAIL_BATCH_MODIFY_MESSAGES"
    "GMAIL_CREATE_FILTER"
    "GMAIL_CREATE_LABEL"
    "GMAIL_DELETE_FILTER"
    "GMAIL_DELETE_LABEL"
    "GMAIL_DELETE_MESSAGE"
    "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID"
    "GMAIL_FETCH_MESSAGE_BY_THREAD_ID"
    "GMAIL_GET_ATTACHMENT"
    "GMAIL_GET_LABEL"
    "GMAIL_LIST_FILTERS"
    "GMAIL_LIST_HISTORY"
    "GMAIL_LIST_LABELS"
    "GMAIL_MODIFY_THREAD_LABELS"
    "GMAIL_MOVE_TO_TRASH"
    "GMAIL_PATCH_LABEL"
    "GMAIL_REMOVE_LABEL"
    "GMAIL_UPDATE_LABEL"
    "OUTLOOK_CREATE_EMAIL_RULE"
    "OUTLOOK_CREATE_MAIL_FOLDER"
    "OUTLOOK_DELETE_EMAIL"
    "OUTLOOK_DELETE_EMAIL_RULE"
    "OUTLOOK_DELETE_MESSAGE"
    "OUTLOOK_GET_EMAIL"
    "OUTLOOK_GET_MAIL_FOLDER"
    "OUTLOOK_GET_MESSAGE"
    "OUTLOOK_GET_MESSAGE_BY_ID"
    "OUTLOOK_LIST_CHILD_FOLDERS"
    "OUTLOOK_LIST_EMAIL_RULES"
    "OUTLOOK_LIST_MAIL_FOLDERS"
    "OUTLOOK_MOVE_EMAIL"
    "OUTLOOK_MOVE_MESSAGE"
    "OUTLOOK_SEARCH_MESSAGES"
    "OUTLOOK_UPDATE_EMAIL_RULE"
  ];

  # Shape matches live mcp-proxy.json backends.composio (filters.py).
  composioBackend = {
    path = "/composio";
    upstream = "https://connect.composio.dev/mcp";
    auth = {
      mode = "auto";
      tag = "[auth via proxy] ";
    };
    headers = { };
    advertise = { };
    secrets.Authorization = {
      credential = "composio-Authorization";
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
    tools = {
      allow = [ ];
      deny = deniedMailTools;
    };
    toolkits = {
      gmail = {
        match.names = [
          "GMAIL_FETCH_EMAILS"
          "GMAIL_LIST_THREADS"
        ];
        allow = [ ];
        deny = [ ];
        byTool = { };
        args = {
          query = gmailQueryGuard;
          label_ids.unset = true;
        };
      };
      outlook = {
        match.names = [
          "OUTLOOK_QUERY_EMAILS"
        ];
        allow = [ ];
        deny = [ ];
        byTool = { };
        args.folder = outlookFolderGuard;
      };
    };
  };
in
{
  # No OAuth on the client — proxy injects Authorization from LoadCredential.
  services.hermes-agent.mcpServers.composio = {
    url = "http://127.0.0.1:3140/composio";
    connect_timeout = 400;
    timeout = 180;
  };

  # Drop-in payload for mcp-proxy.service.
  # Point the unit at /etc/mcp-proxy.json (full) or merge composio-backend.json
  # as backends.composio.
  environment.etc."mcp-proxy/composio-backend.json" = {
    text = builtins.toJSON composioBackend;
    mode = "0644";
  };
  environment.etc."mcp-proxy.json" = {
    text = builtins.toJSON {
      listen = "127.0.0.1:3140";
      backends.composio = composioBackend;
    };
    mode = "0644";
  };

  # First-party rules (Composio Enhanced Controls blocked API create).
  # Gmail → Settings → Filters → Create a new filter. Also apply to matching.
  # Label: agent-blocked. Action: Skip Inbox + Apply label. Do not mark read.
  #
  # Gmail query (keeps "confirm/verify your email" / "welcome to" in inbox):
  # (subject:("security alert" OR "password reset" OR "reset your password" OR "reset password" OR "forgot your password" OR "password has been changed" OR "password changed" OR "password was changed" OR "new device" OR "new sign-in" OR "new sign in" OR "new login" OR "logged in on a new" OR "login from a new" OR "signed in on a new" OR "verify it's you" OR "was this you" OR "did you just" OR "unusual activity" OR "unusual sign-in" OR "unusual sign in" OR "approve AgentCard" OR "limit increase" OR "click to approve" OR "approve this" OR "approve sign-in" OR "approve login" OR "confirm this payment" OR "confirm your payment" OR "confirm this purchase" OR "confirm this transfer" OR "authorize this" OR "authorise this" OR "recovery email" OR "recovery phone" OR "account recovery" OR "action required for two-step" OR "two-factor authentication" OR "new app(s) connected" OR "oauth application has been added" OR "third-party OAuth" OR "code for Login" OR "login code" OR "sign-in code" OR "signin code" OR "Access login code" OR "one-time passphrase" OR "one-time password") OR from:(no-reply@accounts.google.com OR team@notify.agentcard.ai OR account-security-noreply@accountprotection.microsoft.com OR families-noreply@google.com)) -subject:("confirm your email" OR "verify your email" OR "confirm your email address" OR "verify your email address" OR "please confirm your account" OR "confirm your account" OR "activate your account" OR "verify your account" OR "complete your registration" OR "finish signing up" OR "welcome to")
  #
  # Outlook → folder agent-blocked, then rules (exceptions: confirm/verify your email, welcome to):
  #  1. subject contains: security alert, password reset, reset your password, new device, new sign-in, unusual activity, verify it's you
  #  2. subject contains: approve AgentCard, limit increase, click to approve, confirm this payment, confirm this purchase, authorize this
  #  3. subject contains: new app(s) connected, oauth application has been added, third-party OAuth, code for Login, login code, Access login code, one-time passphrase
}
