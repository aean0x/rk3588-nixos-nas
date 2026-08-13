# Maton MCP client (stdio) + secret-injecting wrapper.
# See integrations/AGENTS.md.
{
  lib,
  hermes,
  ...
}:
{
  services.hermes-agent.mcpServers.maton = {
    command = "${hermes.data}/bin/maton-mcp";
    args = [ ];
    env = {
      HOME = hermes.containerHome;
      HERMES_HOME = "${hermes.data}/.hermes";
      PATH = hermes.containerPath;
    };
  };

  system.activationScripts.hermes-mcp-maton = lib.stringAfter [ "hermes-toolbox" ] ''
    install -d -m 0755 -o hermes -g hermes ${hermes.bin}
    install -m 0755 -o hermes -g hermes ${./maton-mcp.sh} ${hermes.bin}/maton-mcp
  '';
}
