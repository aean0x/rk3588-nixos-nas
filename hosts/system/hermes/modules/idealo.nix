# idealo price comparison MCP (github.com/idealo/mcp-server-guide).
#
# Remote Streamable HTTP on idealo's own domain. OAuth 2.0 authorization-code
# with Dynamic Client Registration + PKCE as a public client, so there is no
# secret to declare here: after deploy run `hermes mcp login idealo` once
# (skill mcp-oauth-setup) and the tokens land in $HERMES_HOME/mcp-tokens/.
# `oauth.redirect_port` is deliberately absent — the module type has no such
# option, so set it in config.yaml if the login needs a pinned port.
#
# HELD DISABLED, and the hold lives here for a reason. With no cached tokens the
# client parks the server on every start and then self-probes every 300 s,
# writing two WARN lines to errors.log/agent.log each time (~470 lines/day,
# three quarters of errors.log) and swamping the surface real faults are read
# from (kanban t_ca72916e, t_7f1fb500). A hand edit to
# `mcp_servers.idealo.enabled` in the live config.yaml does NOT hold: activation
# deep-merges `settings` into config.yaml and rewrites every key a declared
# server owns (hermes-agent nix/moduleCommon.nix — `mcpServerType` defaults
# `enabled = true`, `mcpServersToConfig` always emits it), so the next
# `./deploy remote-switch` re-asserts true.
#
# The login is also blocked independently: Hermes enforces RFC 8414 §3.3 on
# idealo's authorization-server metadata and aborts with an issuer mismatch
# (probed 2026-09-22, skill mcp-oauth-setup). Re-enable only after a TTY login
# succeeds: set `enabled = true` here, `./deploy remote-switch`, then
# `hermes mcp login idealo`. Keep `mcp_servers.idealo.oauth.redirect_port: 6274`
# in config.yaml — the module type has no option for it.
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
    enabled = false;
  };
}
