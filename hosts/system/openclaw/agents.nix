{ oc, ... }:

let
  # ── Tool Policy ────────────────────────────────────────────
  # Strategy: profile "full" gives every tool. tools.deny removes what's not needed.
  # In this flexible layout, all sub-agents share a blanket set of granted tools.

  commonTools = [
    "read"
    "write"
    "edit"
    "browser"
    "web_search"
    "web_fetch"
    "image"
    "memory_search"
    "memory_get"
    "agents_list"
    "session_status"
    "tts"
    "pdf"
    "sessions_list"
    "sessions_history"
    "sessions_send"
    "sessions_yield"
  ];

  # Tools that are powerful but granted to all sub-agents under the flat structure
  privilegedTools = [
    "exec"
    "apply_patch"
    "process"
    "sessions_spawn"
    "subagents"
  ];

  # Admin tools that are unconditionally denied to all sub-agents
  adminTools = [
    "cron"
    "gateway"
    "nodes"
    "message"
    "canvas"
  ];

  # Secrets every sub-agent gets
  defaultSecrets = {
    BRAVE_API_KEY = oc.env "BRAVE_API_KEY";
    GOOGLE_PLACES_API_KEY = oc.env "GOOGLE_PLACES_API_KEY";
    BROWSERLESS_API_TOKEN = oc.env "BROWSERLESS_API_TOKEN";
  };

  # Main and Sub-Agent Configuration (used to generate JSON)
  mkAgentsConfig =
    {
      gatewayUrl,
    }:
    {
      tools = {
        subagents.tools.deny = adminTools;
        # Sandbox tool filter (layer 7).
        # Wildcards don't work here — must use explicit group names.
        # This is a separate gate from tools.profile; both must permit a tool.
        sandbox.tools = {
          allow = [
            "group:fs"
            "group:runtime"
            "group:sessions"
            "group:web"
            "group:memory"
            "group:ui"
            "group:openclaw"
            "lobster"
            "image"
          ];
          deny = [ ];
        };
      };

      defaults = {
        sandbox = {
          mode = "non-main";
          workspaceAccess = "rw";
          scope = "agent";
          docker = {
            image = oc.sandboxImage;
            readOnlyRoot = true;
            network = "bridge";
            user = "1000:1000";
            capDrop = [ "ALL" ];
            env =
              oc.containerEnv
              // {
                OPENCLAW_GATEWAY_TOKEN = oc.env "OPENCLAW_GATEWAY_TOKEN";
                OPENCLAW_GATEWAY_URL = gatewayUrl;
              }
              // defaultSecrets;
            cpus = 1;
          };
        };
      };

      list = [
        {
          id = "main";
          subagents.allowAgents = [ "*" ];
          sandbox.mode = "off";
          tools = {
            profile = "full";
            deny = [
              "group:web"
              "group:messaging"
              "group:ui"
            ];
          };
        }
        {
          id = "helper";
        }
      ];
    };

in
{
  inherit
    commonTools
    privilegedTools
    adminTools
    defaultSecrets
    mkAgentsConfig
    ;
}
