# idealo price comparison MCP (github.com/idealo/mcp-server-guide).
#
# Remote Streamable HTTP on idealo's own domain. OAuth 2.0 authorization-code
# with Dynamic Client Registration + PKCE as a public client, so there is no
# secret to declare here: after deploy run `hermes mcp login idealo` once
# (skill mcp-oauth-setup) and the tokens land in $HERMES_HOME/mcp-tokens/.
# `oauth.redirect_port` is deliberately absent — the module type has no such
# option, so set it in config.yaml if the login needs a pinned port.
#
# Before the first login the gateway's discovery probe finds no token and the
# server reports disconnected. If that probe races the login flow, set
# `enabled: false` in config.yaml, log in, then set it back to true.
#
# Tools (read-only): search_products, get_product_details, get_product_offers,
# get_product_price_history. Trial tier: 3 req/s, 6 burst, 500 calls/day.
# idealo's compliance blocklist strips Amazon, eBay and Otto offers at every
# tier, so idealo is a cross-shop price signal and never the source for those
# three shops (skill shopping-board).
{
  services.hermes-agent.mcpServers.idealo = {
    url = "https://mcp.idealo.com/mcp";
    auth = "oauth";
    connect_timeout = 400;
    timeout = 120;
  };
}
