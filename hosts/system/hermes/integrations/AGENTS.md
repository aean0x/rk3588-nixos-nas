# Hermes integrations

Single home for first-party **plugins**, **MCP clients**, and related install wiring.
Infrastructure only — not agent-owned workspace content.

## Layout

```
integrations/
├── AGENTS.md              # this file
├── default.nix            # plugins.enabled + install (plugins, HMC, gbrain skills)
├── hmc.nix                # fetch upstream HMC + write config.yaml (no source overlay)
├── plugins/               # in-tree plugin sources
│   ├── gbrain-retrieval-reflex/
│   ├── gbrain-memory-flush/
│   ├── tool-call-coherency/
│   ├── projects-auto-commit/
│   └── model-router/      # + webui/ extension sidecar
└── mcp/
    ├── default.nix        # imports MCP client modules
    ├── maton.nix          # stdio maton + /data/bin/maton-mcp wrapper
    └── maton-mcp.sh       # wrapper source (secrets via .env)
```

## Plugins (enabled)

Declared once in `default.nix` (`enabledPlugins`):

| Name | Role |
|------|------|
| `hermes-context-manager` | HMC — upstream pin + our `config.yaml` (cheap tool-output only; native owns LLM compact) |
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

**HMC** is stock upstream plus a generated `config.yaml`. Native Hermes
`compression.threshold_tokens` does LLM compact; HMC only truncates / filters
tool output (`background_compression` is off so the two do not double-summarize).

**Bytecode / mtime:** Nix sources carry epoch mtimes. Activation wipes
`__pycache__` and `touch`es all `.py` after install so Python cannot prefer a
stale `.pyc` over freshly deployed source. Manual hot-fix must do the same
(`touch` + purge pyc + restart) — see skill `hermes-plugin-ops` §6.

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
| `../skills/` | Skill *source*; this module copies gbrain skills into `skills.external_dirs` |
| `../scripts/projects_auto_commit.py` | Installed next to the auto-commit plugin |
| `../scripts/git-credential-github-env` | Installed from `gbrain.nix` (GITHUB_PAT for `~/brain` + hermes-user git) |
