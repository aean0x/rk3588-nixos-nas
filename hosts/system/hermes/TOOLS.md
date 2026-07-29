# Hermes tool catalogue (rocknas) — exposure model

Aligned with Hetzner `modules/hermes-agent.nix` toolbox + MCP pattern.

## Exposure layers

| Layer | Where | How agent sees it |
|-------|--------|-------------------|
| **Toolbox** | Host `/var/lib/hermes/toolbox/bin` → container `/data/toolbox/bin` | `PATH` on gateway + terminal + MCP children |
| **Bun globals** | `~/.bun/bin` (e.g. `gbrain`) | After `bun install -g` in container |
| **npm globals** | `~/.npm-global/bin` (e.g. `agent-browser`) | After `npm install -g` |
| **Workstation helpers** | Host `~/.local/bin` (ssh-workstation, …) | Host PATH only (not first on agent PATH) |
| **Host Brave CDP** | `hermes-browser.service` :9222 | `BROWSER_CDP_URL` + `browser.cdp_url` |
| **Cookie warm** | `hermes-browser-import-cookies` | Netscape / Playwright JSON → CDP `Network.setCookie` |
| **MCP** | `mcpServers.gbrain` → `gbrain serve` | Tools `mcp_gbrain_*` (via tool_search) |

## PATH order (container / gateway)

```
~/.npm-global/bin : ~/.bun/bin : /data/toolbox/bin : /run/current-system/sw/bin : …
```

## PATH order (host login / hermes CLI)

```
/var/lib/hermes/toolbox/bin : ~/.bun/bin : ~/.npm-global/bin : ~/.local/bin : …
```

Toolbox **first** so host `bun` is Nix `pkgs.bun` (not curl stub-ld).

## Toolbox packages (buildEnv)

python3(+requests,pyyaml,toml), pandoc, bun, nodejs, git, ripgrep, jq, yq-go,
curl, wget, unzip, zip, imagemagick, tree, rsync, openssh, ffmpeg, sox,
poppler-utils, gnupg, age, file, which, coreutils, findutils, gawk, gnused,
gnutar, gzip, bzip2, xz, zstd, p7zip, htop, ncdu, lsof, strace, tcpdump, nmap,
netcat-gnu, socat, chromium→chrome/google-chrome aliases.

## Env (gateway)

| Variable | Value |
|----------|--------|
| `PATH` | agent path above |
| `HERMES_PY` / `HERMES_PYTHON` | `/data/toolbox/bin/python3` |
| `AGENT_BROWSER_EXECUTABLE_PATH` | `/data/toolbox/bin/chromium` |
| `BROWSER_CDP_URL` | `http://127.0.0.1:9222` (browser.nix) |
| `browser.cdp_url` | same (config.yaml) |

## MCP

| Server | Command | Notes |
|--------|---------|--------|
| gbrain | `gbrain serve` | Bare name; PATH must include `~/.bun/bin` |
| maton | `npx -y @maton/mcp` | Needs npm + network |
| robinhood-crypto | `robinhood-mcp-readonly` → `npx -y robinhood-mcp` | **Read-only** crypto data server; secrets via `/run/hermes-robinhood.env`; trading binary NOT enabled |

## Gaps vs Hetzner (closed)

| Item | Hetzner | rocknas |
|------|---------|---------|
| buildEnv toolbox packages | strace/tcpdump/nmap/chromium aliases | same |
| Agent PATH | npm → bun → toolbox → sw | same |
| Host CLI PATH | toolbox first (Nix bun) | same + `~/.local/bin` for workstation helpers |
| `AGENT_BROWSER_EXECUTABLE_PATH` | toolbox chromium | same |
| MCP gbrain | bare `gbrain serve` + PATH env | same |
| `hermes-cli` wrapper | `/var/lib/hermes/bin/hermes-cli` | same |
| sudo NOPASSWD | hermes-cli + hermes | same |
| Dotenv PATH | stripped (host-safe); container via service/docker env | same — strip PATH/HERMES_PY/AGENT_BROWSER from `.env`; host CLI uses hermes-cli PATH |

Intentional rocknas extras: host sticky Chromium CDP (`browser.nix`), OneDrive sync, gbrain consolidate/embed/dream timers.

## Host CLI routing note

Upstream `is_container()` false-positives on Docker **hosts** (mountinfo contains
`/var/lib/docker` / `containerd`), so host `hermes` never auto-execs into the
container. **`/var/lib/hermes/bin/hermes-cli` forces `docker exec`** when
`.container-mode` is present — agent terminal then sees `/data/toolbox/bin`.
