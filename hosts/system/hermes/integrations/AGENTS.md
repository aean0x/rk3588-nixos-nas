# Hermes integrations

Single home for first-party **plugins**, **MCP clients**, and related install wiring.
Infrastructure only — not agent-owned workspace content.

## Layout

```
integrations/
├── AGENTS.md              # this file
├── default.nix            # plugins.enabled + plugin install activation
├── plugins/               # force-managed sources (materialize → /var/lib/hermes/plugins, symlink → $HERMES_HOME/plugins)
│   ├── gbrain-retrieval-reflex/
│   ├── gbrain-memory-flush/
│   ├── tool-call-coherency/
│   ├── projects-auto-commit/
│   ├── model-router/      # + webui/ extension sidecar
│   └── hermes-context-manager-overlay/  # overlay for pinned HMC
└── mcp/
    ├── default.nix        # imports MCP client modules
    ├── maton.nix          # stdio maton + /data/bin/maton-mcp wrapper
    └── maton-mcp.sh       # wrapper source (secrets via .env)
```

## Plugins (enabled)

Declared once in `default.nix` (`enabledPlugins`):

| Name | Role |
|------|------|
| `hermes-context-manager` | HMC — pinned upstream + overlay (`context-manager.nix`) |
| `gbrain-retrieval-reflex` | Ambient brain pointers over HTTP MCP |
| `gbrain-memory-flush` | Prompt to flush durable notes via gbrain MCP |
| `tool-call-coherency` | Fix double-wrapped / cold MCP tool calls |
| `projects-auto-commit` | EOT monorepo commit for projects tree |
| `model-router` | T1 Flash / T2 Pro / T3 Grok per-turn routing |

**One install pattern for every plugin** (including HMC):

1. **Materialize** full tree → `/var/lib/hermes/plugins/<name>` (container: `/data/plugins/<name>`)
2. **Discover** via relative symlink → `$HERMES_HOME/plugins/<name>` → `../../plugins/<name>`
   (container: `/data/.hermes/plugins/<name>`)

Hermes only scans `$HERMES_HOME/plugins`. `plugins.external_dirs` is not a Hermes
feature (skills-only); activation strips that dead key from live config. If a prior
dual-copy left a real directory at the discovery path, activation replaces it with
the symlink.

**HMC** uses the same shape in `context-manager.nix` (fetch + overlay into the
materialize root, then the same relative symlink).

**model-router WebUI** assets stay in-flake at `plugins/model-router/webui`;
`hermes-webui.nix` sets `HERMES_WEBUI_EXTENSION_DIR` to that store path.

## MCP clients

| Server | Module | Transport | Notes |
|--------|--------|-----------|--------|
| `maton` | `mcp/maton.nix` | stdio via `/data/bin/maton-mcp` | Wrapper sources `.env` (stdio filter strips ambient secrets) |
| `gbrain` | `../gbrain.nix` | HTTP `http://127.0.0.1:3131/mcp` | Sole serve = `gbrain-mcp-http`; token re-apply in activation |

Agent-configured MCP (robinhood, composio, …) lives in live `config.yaml` only —
not declarative.

## Adding something

1. **Plugin:** drop tree under `plugins/<name>/` with `plugin.yaml` + `__init__.py`,
   append name to `enabledPlugins` in `default.nix`.
2. **MCP client:** add `mcp/<name>.nix` that sets `services.hermes-agent.mcpServers.<name>`,
   import it from `mcp/default.nix`. Prefer a wrapper under `mcp/` if secrets need
   injection for stdio.
3. Restart: `systemctl restart hermes-agent` (and webui if extension paths change).

## Related (not here)

| Path | Why separate |
|------|----------------|
| `gbrain.nix` | HTTP serve unit + memory registry + token wiring |
| `context-manager.nix` | Upstream pin + overlay install |
| `skills/` | Agent skills (policy text), not Hermes plugins |
| `scripts/` | Ops / helpers (e.g. `projects_auto_commit.py`) |
