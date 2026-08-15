# Declarative Hermes MCP clients (stdio wrappers + HTTP URLs).
# gbrain HTTP client + serve unit: ../gbrain.nix (token re-apply lives there).
{
  imports = [
    ./composio.nix
    ./policylayer-mcp.nix
  ];
}
