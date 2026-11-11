# PolicyLayer MCP registry — the vetting gate for MCP servers (skill
# policylayer-mcp). Free single-server lookups, no auth, no secrets.
# Tools: search_registry, check_mcp_server, check_tool (+ get_change_events,
# licence-gated). Direct HTTP client like gbrain; no proxy hop needed.
#
# HELD DISABLED 2026-11-11: upstream answers HTTP 502 ("Application failed to
# respond") on /mcp and on / since 2026-11-10 09:18Z, and Glama lists the
# connector Unhealthy at 0.0% uptime over the last 24 h. Each failed connect
# parks the server, then the next reconcile re-adds policylayer-mcp from config
# (102 x `reconciled with config ... added=['policylayer-mcp']` between
# 2026-11-10 11:33Z and 2026-11-11 05:14Z), so the storm refilled errors.log
# every ~11 min for a provider outage that is not ours (kanban t_746469e6). The
# last healthy `POST ... 200 OK` is 2026-11-08 05:42Z.
#
# Reopen: probe `curl -sS -o /dev/null -w '%{http_code}' https://api.policylayer.com/mcp`
# until it stops answering 5xx (a bare GET may answer 400/401/405/406 — any of
# those means alive), then set `enabled = true;` here and deploy. While held,
# one-off lookups go through policylayer.com/registry. A hand edit to
# `mcp_servers.policylayer-mcp.enabled` in the live config.yaml does NOT hold:
# activation deep-merges `settings` into config.yaml and re-asserts every key a
# declared server owns (`mcpServerType` defaults `enabled = true`), the reason
# the idealo hold lives in its module too.
{
  services.hermes-agent.mcpServers.policylayer-mcp = {
    url = "https://api.policylayer.com/mcp";
    connect_timeout = 60;
    timeout = 120;
    enabled = false;
  };
}
