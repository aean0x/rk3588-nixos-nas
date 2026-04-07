{ oc, ... }:

let
  # Secrets every sub-agent gets
  defaultSecrets = {
    BRAVE_API_KEY = oc.env "BRAVE_API_KEY";
    GOOGLE_PLACES_API_KEY = oc.env "GOOGLE_PLACES_API_KEY";
    BROWSERLESS_API_TOKEN = oc.env "BROWSERLESS_API_TOKEN";
    MATON_API_KEY = oc.env "MATON_API_KEY";
  };

  # Main and Sub-Agent Configuration (used to generate JSON)
  mkAgentsConfig =
    {
      gatewayUrl,
    }:
    {
      tools = {
        # Sandbox tool filter (layer 7).
        # Wildcards don't work here — must use explicit group names.
        # This is a separate gate from tools.profile; both must permit a tool.
        sandbox.tools = {
          allow = [
            # Core filesystem & runtime (read/write/exec etc.)
            "group:fs"
            "group:runtime"

            # Web & browser
            "group:web"
            "browser"
            "web_search"
            "web_fetch"

            # Memory
            "group:memory"

            # UI / media / generation (browser, tts, image_generate, etc.)
            "group:ui"

            # Safe session coordination (list/history/send/yield/status — no spawning)
            "group:sessions"

            # OpenClaw internals + your custom extras
            "group:openclaw"
            "group:agents"
            "lobster"
            "image"

            # Extra explicit tools that sometimes sit outside groups
            "pdf"
            "code_execution"
            "apply_patch"
          ];
          deny = [ ]; # Deny list is implicit from allow list.
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
            tmpfs = [
              "/tmp:size=512m,mode=1777"
              "/dev/shm:size=256m"
              "/home/node/.cache"
              "/home/node/.local"
              "/home/node/.npm"
              "/var/tmp"
            ];
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
          subagents.allowAgents = [ "helper" ];
          subagents.requireAgentId = true;
          sandbox.mode = "off";
          tools = {
            profile = "full";
            deny = [
              "group:web"
              "group:ui"
            ];
          };
        }
        {
          id = "helper";
          workspace = oc.hostWorkspace;
        }
      ];
    };

in
{
  inherit
    defaultSecrets
    mkAgentsConfig
    ;
}
