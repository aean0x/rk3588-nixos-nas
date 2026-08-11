# Maton MCP client (stdio) + secret-injecting wrapper.
# See integrations/AGENTS.md.
{
  lib,
  ...
}:
let
  # Container sees stateDir as /data; host path is /var/lib/hermes/bin/maton-mcp.
  containerBin = "/data/bin/maton-mcp";
in
{
  services.hermes-agent.mcpServers.maton = {
    command = containerBin;
    args = [ ];
    env = {
      HOME = "/home/hermes";
      HERMES_HOME = "/data/.hermes";
      PATH = "/data/toolbox/bin:/home/hermes/.npm-global/bin:/usr/local/bin:/usr/bin:/bin";
    };
  };

  system.activationScripts.hermes-mcp-maton = lib.stringAfter [ "hermes-toolbox" ] ''
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    install -m 0755 -o hermes -g hermes ${./maton-mcp.sh} /var/lib/hermes/bin/maton-mcp
  '';
}
