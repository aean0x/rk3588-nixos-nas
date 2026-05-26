# Hermes Agent (NousResearch) — AI agent with Docker container, web dashboard,
# OneDrive sync, Telegram/web messaging, memory, cron, and declarative MCP servers.
#
# Exposes a web dashboard at hermes.<domain> (LAN-only) via Caddy.
# MATON_API_KEY and other API keys are injected from SOPS at runtime (/run/hermes.env).
#
# Setup:
#   1. Ensure API keys are present in secrets/secrets.yaml.work (maton_api_key, etc.)
#   2. Uncomment ./services/hermes.nix in hosts/system/services.nix
#   3. Deploy: ./deploy remote-switch
#   4. Open https://hermes.<domain> for the web dashboard
#
# The hermes CLI is available system-wide: `hermes chat`, `hermes doctor`, etc.
{ ... }:
{
  imports = [ ../hermes ];

  # ===================
  # MCP servers (stdio/npx transport)
  # ===================
  # These run as child processes of hermes-agent inside the container.
  # MATON_API_KEY (and other keys) are inherited from the hermes process environment,
  # which is populated from /run/hermes.env via environmentFiles at startup.
  services.hermes-agent.settings.mcpServers = {
    maton = {
      command = "npx";
      args = [
        "-y"
        "@maton/mcp"
      ];
      # MATON_API_KEY is inherited from hermes environment (/run/hermes.env → environmentFiles).
      # No explicit env block needed; hermes passes its env to all stdio MCP subprocesses.
    };
  };
}
