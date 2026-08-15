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
    ├── default.nix        # imports client modules
    └── composio.nix       # Composio backend + Hermes client via mcp-proxy flake
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
`compression.threshold_tokens` (180k cap) + `model_thresholds.deepseek-v4`
does LLM compact; HMC only truncates / filters
tool output (`background_compression` is off so the two do not double-summarize).

**Bytecode / mtime:** Nix sources carry epoch mtimes. Activation wipes
`__pycache__` and `touch`es all `.py` after install so Python cannot prefer a
stale `.pyc` over freshly deployed source. Manual hot-fix must do the same
(`touch` + purge pyc + restart) — see skill `hermes-plugin-ops` §6.

**model-router WebUI** assets stay in-flake at `plugins/model-router/webui`;
`hermes-webui.nix` sets `HERMES_WEBUI_EXTENSION_DIR` to that store path.

## MCP clients

Hermes never talks to secret-bearing remotes directly. `services.mcpProxy`
listens on loopback, injects sops-backed headers, and applies toolkit filters
to `tools/call` (including unwrapped inner slugs such as Composio
`COMPOSIO_MULTI_EXECUTE_TOOL.tools[].tool_slug`).

| Server | Module | Transport | Notes |
|--------|--------|-----------|--------|
| `mcp-proxy` | flake `github:aean0x/mcp-proxy` | HTTP `127.0.0.1:3140/<backend>` | `nixosModules.default`; `LoadCredential` for secrets |
| `composio` | `mcp/composio.nix` | HTTP via proxy → `https://connect.composio.dev/mcp` | Bearer from `composio_api_key`; Gmail query exclude-label filter |
| `gbrain` | `../gbrain.nix` | HTTP `http://127.0.0.1:3131/mcp` | Sole serve = `gbrain-mcp-http`; token re-apply in activation |

Agent-configured MCP (robinhood, …) lives in live `config.yaml` only —
not declarative.

Declare a new proxied server:

```nix
services.mcpProxy.backends.example = {
  upstream = "https://example.example/mcp";
  secrets.Authorization = {
    file = config.sops.secrets.example_api_key.path;
    prefix = "Bearer ";
  };
  unwrap = [{ tool = "META_EXECUTE"; each = "tools"; name = "slug"; args = "arguments"; }];
  toolkits.gmail = {
    prefix = "GMAIL_";
    deny = [ "GMAIL_DELETE_*" ];
    args.query.requireTokens = [ "-label:archive" ];
    args.query.denyTokens = [ "label:archive" ];
  };
};
services.hermes-agent.mcpServers.example.url =
  "http://127.0.0.1:${toString config.services.mcpProxy.listenPort}/example";
```

Field injection applies to **matched tool names** (including omitted args).
Match the tools that actually take that field — a `GMAIL_` prefix would also
create `query=` on `GMAIL_LIST_LABELS`. Composio meta-calls need an `unwrap`
so toolkit rules see `GMAIL_FETCH_EMAILS` inside `COMPOSIO_MULTI_EXECUTE_TOOL`.
`COMPOSIO_REMOTE_WORKBENCH` can still shell `run_composio_tool(...)` and bypass
unwrap; deny that surface tool if you need a hard guarantee.

## Adding something

1. **Plugin:** drop tree under `plugins/<name>/` with `plugin.yaml` + `__init__.py`,
   append name to `enabledPlugins` in `default.nix`.
2. **MCP client:** add `mcp/<name>.nix` that declares `services.mcpProxy.backends.<name>`
   (secret + filters) and points `services.hermes-agent.mcpServers.<name>` at the
   proxy path. Import it from `mcp/default.nix`.
3. Restart: `systemctl restart mcp-proxy hermes-agent` (and webui if extension paths change).

## Related (not here)

| Path | Why separate |
|------|----------------|
| `gbrain.nix` | HTTP serve unit + memory registry + token wiring |
| `../skills/` | Skill *source*; this module copies gbrain skills into `skills.external_dirs` |
| `../scripts/projects_auto_commit.py` | Installed next to the auto-commit plugin |
| `../scripts/git-credential-github-env` | Installed from `gbrain.nix` at `/home/hermes/.local/bin` (GITHUB_PAT for `~/brain` + host/container git) |
