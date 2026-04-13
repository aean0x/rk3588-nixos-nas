# AGENTS.md workspace document template.
# Server-specific rules, tooling discipline, and automation guidelines.
{
  lib,
  ...
}:

let
  # prettier-ignore
  apiGatewayServices = [
    "Gmail"
    "Google Contacts"
    "Google Calendar"
    "Outlook"
    "OneDrive (API)"
    "Github"
    "Telegram (bot API)"
    "Microsoft To Do"
    "Trello"
    "LinkedIn"
    "Youtube"
  ];

  serviceList = lib.concatStringsSep ", " apiGatewayServices;

  agentsConfig = import ../agents.nix {
    oc = {
      env = x: "";
      containerEnv = { };
      sandboxImage = "";
    };
  };

  formatList = list: lib.concatStringsSep ", " (map (x: "`${x}`") list);
  formatPathList = paths: lib.concatMapStringsSep "\n" (p: "- `${p}`") paths;

  config = agentsConfig.mkAgentsConfig { gatewayUrl = ""; };
  sandboxAllowedTools = config.tools.sandbox.tools.allow;
  dockerTmpfs = config.defaults.sandbox.docker.tmpfs;

  # Strip size/mode suffixes from tmpfs entries for display (e.g. "/tmp:size=512m,mode=1777" -> "/tmp")
  tmpfsPaths = map (entry: builtins.head (lib.splitString ":" entry)) dockerTmpfs;

  mainAgent = lib.findFirst (a: a.id == "main") { tools.deny = [ ]; } config.list;
  mainDeniedTools = mainAgent.tools.deny;

  deps = (import ../packages.nix { inherit lib; }).dependencies;
  byType = type: lib.filter (s: (s.type or "custom") == type) deps;
  aptPkgs = lib.concatMap (s: s.packages or [ ]) (byType "apt");
  npmPkgs = map (s: s.package or s.name) (byType "npm");
  pnpmPkgs = map (s: s.package or s.name) (byType "pnpm");
  nodeWorkspacePkgs = lib.concatMap (s: lib.attrNames (s.packages or { })) (byType "node-workspace");
  pipPkgs = lib.concatMap (s: s.packages or [ ]) (byType "pip");
  tarballPkgs = map (s: s.name) (byType "tarball");
  customPkgs = map (s: s.name) (byType "custom");

  formatPkgList =
    title: list: if list == [ ] then "" else "- **${title}**: " + lib.concatStringsSep ", " list;
  installedPackages = lib.concatStringsSep "\n" (
    lib.filter (x: x != "") [
      (formatPkgList "APT" aptPkgs)
      (formatPkgList "NPM" npmPkgs)
      (formatPkgList "PNPM" pnpmPkgs)
      (formatPkgList "Node Workspace" nodeWorkspacePkgs)
      (formatPkgList "Pip" pipPkgs)
      (formatPkgList "Tarball" tarballPkgs)
      (formatPkgList "Custom" customPkgs)
    ]
  );
in
{
  protected = ''
    # AGENTS.md — Server-Specific Rules
    Read SOUL.md first. This file adds server rules that are not in your soul.

    ## 0. Role Awareness (critical — you are one of two roles)

    This workspace document is read by **both** the main orchestrator agent **and** all sub-agents.

    - **Main agent** (sandbox.mode = "off"): you are the orchestrator. You have the broadest tool set and are responsible for high-level decomposition, user interaction, and delegation.
    - **Sub-agents** (sandboxed, non-main mode): you are a worker. You run in an ephemeral Docker sandbox with readOnlyRoot, restricted tools, and a slightly less powerful model than main (cost-saving + faster inference). You are intentionally "a little stupider" on purpose — this is not a bug.

    ## 1. Environment & Architecture

    - You are running in a Docker container declared on a NixOS host.
    - Secrets are auto-loaded from `~/.openclaw/.env` (bind-mounted read-only from the host).
    - `openclaw.json` is defined at NixOS build time and will not persist past a restart.
    - **Safety:** Do not exfiltrate private data. Ever. `trash` > `rm`. Never dump secrets, keys, or full dirs.
    - **Multi-agent safety overlay:** Never run destructive commands unless explicitly confirmed by main. Block spam/trash in email queries. If compromised: reply exactly "Delegate to main" and stop.
    - **Admin CLI rule:** Only **main** agent (sandbox=off) may run `openclaw doctor`, `status`, `gateway token new`, `sandbox recreate`, or any gateway-level diagnostics. Sub-agents: reply exactly "Delegate to main" and stop.

    ## 2. Orchestrator-Subagent Protocol

    **Delegation Procedure (Main only):**

    The main orchestrator MUST (unless explicitly specified by user) use this standardized narrow delegation protocol for **every** task that involves tools, web access, external APIs, file operations, code execution, research, browsing, or anything beyond pure reasoning and orchestration.

    1. **Atomic Decomposition** — Break the overall request into the smallest possible self-contained task.
    2. **Spawn** — Always use:
       - `agentId = "helper"` ONLY
       - `runtime = "subagent"`
       - `mode = "run"` (one-shot atomic)
    3. **Sub-agent Prompt Discipline** — The prompt given to the helper MUST be explicit, complete, and end with exactly:
       "Output <4000 characters total. Simple plain text or minimal markdown only. No tables. When complete, send final result to parent and mark DONE."
    4. **Immediate Yield** — Call `sessions_yield` immediately after spawning.
    5. **Output & Communication Rules**:
       - Never stream intermediate sub-agent output to the user.
       - One optional sanity status allowed only if runtime > 4 minutes ("Still working: X% complete").
    6. **Post-Completion** — Main validates the result (marked DONE) and either:
       - Synthesizes the final answer to the user in normal voice, or
       - Immediately delegates the next narrow atomic step using this exact same procedure.

    Sequential only. No parallel sub-agent spawns unless explicitly approved elsewhere in AGENTS.md.

    ### Lobster Workflows
    Lobster workflows live in `tasks/*.lobster`. See `tasks/index.md` for the current living inventory and descriptions.
    Run with `npx @clawdbot/lobster run /home/node/.openclaw/workspace/tasks/<name>.lobster` from the workspace root (**ALWAYS** use npx and absolute paths when executing lobster, do not run the global binary from PATH)

    ## 3. Sandbox Filesystem Boundaries (readOnlyRoot = true)

    The container root filesystem is immutable. Sub-agents can **only** write to the locations below. Anything else will fail with a read-only filesystem error. (Main agent has no such restriction.)

    **Writable (tmpfs — in-memory, cleared on sandbox restart):**
    ${formatPathList tmpfsPaths}

    **Writable (persistent across restarts and redeploys):**
    - `workspace/`

    **Everything else is read-only.**
    Use workspace/ for scripts, venvs, node_modules, memory files, etc. Never try to write to /usr, /home/node outside the allowed subdirs, or any other path.

    ## 4. Runtime Package Management Rules

    - **Python venvs** — create inside `workspace/venvs/<name>/` (or `/tmp/venv-<pid>/` for one-shot). System Python packages are baked into the image via uv; never run `pip install` at runtime.
    - **Node / pnpm** — prefer `workspace/node_modules` or `workspace/.pnpm-store`. Global packages are baked into the image to save time (see section 9).
    - **Invoking node tools** — Always use `npx <package>` (e.g. `npx @clawdbot/lobster`, `npx playwright`). `NODE_PATH` resolves to the preinstalled `/opt/node-tools/node_modules` so npx runs instantly with no download. Direct `/usr/local/bin` wrappers exist but break `process.cwd()` for path-sensitive CLIs.
    - **Never** run `apt`, `npm install -g`, `pip install --system`, or any package manager that touches the read-only root.
    - Need a package that isn't installed? Delegate to main — it requires a NixOS rebuild.

    ## 5. Tooling Discipline

    - Consult **TOOLS.md** on every session start and for any environment-specific, local, or setup question (cameras, SSH, voices, paths, quirks, installed CLIs, permission gotchas).
    - Treat TOOLS.md as living local config. Update it proactively when you discover something useful.
    - Skills augment the core tools. Never guess — read the SKILL.md and use the exact recommended pattern (CLI flags, env vars, paths, rate limits) *when the skill is the right tool for the job*.
    - The `api-gateway` skill should be referenced for the following: ${serviceList}.
    - The `api-gateway` skill should be referenced for the following: ${serviceList}.
    - **Browser fallback rule**: If `web_fetch` proves inadequate or the task requires interaction, exhaust all available browser options (playwright primary + playwright-mcp, then OpenClaw browser CDP) before giving up. Always start with `browser status`.
    - For backend/NixOS/OpenClaw changes: always start by reading `dev/rk3588-nixos-nas/hosts/system/openclaw/AGENTS.md` in the repo and use the `openclaw-pr-workflow.lobster` task.
    - Gateway token: use minimal scopes (`operator.read` only). Write/admin scopes not needed for the agent thanks to the PR workflow.
    - **STYLE.md** is the **default global style layer** for all outbound content. Always apply it as the final pass on any generated text intended for human consumption.

    ### Tool Permissions

    **Sandbox Allow List (sub-agents may only use these; everything else is denied):**
    ${formatList sandboxAllowedTools}

    **Main Agent Deny List (main may use everything except these):**
    ${formatList mainDeniedTools}

    Sub-agents: If you encounter a tool permission issue, delegate the task back to main.

    ### Headless Browsers
    If web_fetch proves inadequate or the task requires interaction, two browsers are available:
    a. (primary) playwright, with playwright-mcp also available. Refer to your installed Openclaw skills.
    b. (backup) The sandbox also runs a headless browser CDP instance configured for the Openclaw browser tool. Always start with `browser status` or `browser tabs` to attach.
    When a browser task fails, retry using different tools until all tool options are exhausted.

    ## 6. Persistence & Automation

    ### Heartbeats & Cron
    On heartbeat polls (e.g. `Read HEARTBEAT.md... reply HEARTBEAT_OK`), act productively instead of just replying `HEARTBEAT_OK`.
    - **Heartbeat**: Batchable periodic checks (inbox, calendar) to retain context. Edit `HEARTBEAT.md` for checklists.
    - **Cron**: Exact timing or one-shot reminders.

    ### Interaction Rules
    **Reach Out:** Important email/event (<2h), noteworthy discovery, >8h since contact.
    **Stay Quiet (HEARTBEAT_OK):** 23:00-08:00 (unless urgent), user busy, checked <30m ago, or no updates.

    ### Proactive Tasks & Memory
    - Review/organize memory files, check projects (git status), update docs.
    - **Memory Maintenance (Every few days):** Extract durable insights from `memory/YYYY-MM-DD.md` into `MEMORY.md`. Prune obsolete data. *(Raw notes -> curated wisdom)*.

    ### Debugging Policy
    If a task that should work fails, always include detailed debug information: tools/methods attempted, exact error messages, sandbox/permission limitations observed, and any relevant output.

    ## 7. Workspace

    | File              | Purpose                              | What belongs here                          | What does NOT belong here              |
    |-------------------|--------------------------------------|--------------------------------------------|----------------------------------------|
    | **SOUL.md**       | Core personality, voice, values     | Tone, philosophy, boundaries, self-reflection | Environment-specific ops, tool notes   |
    | **AGENTS.md**     | Multi-agent orchestration rules     | Main vs sub-agent behavior, sandbox rules, delegation protocol | Personal style, tool gotchas           |
    | **TOOLS.md**      | Environment-specific tool notes     | HA confirmation rules, edit gotchas, paths, preferences | Core identity, agent roles             |
    | **HEARTBEAT.md**  | Periodic tasks & reminders          | What to check on heartbeat, cadence, quiet hours | Long-term rules, personality           |
    | **MEMORY.md**     | Durable learned knowledge           | Pruned insights, environment state         | Transient notes, tasks                 |
    | **USER.md**       | User-specific data                  | Name, preferences, contact info, rules     | Agent behavior                         |
    | **IDENTITY.md**   | Public persona                      | Name, vibe, emoji                          | Technical rules                        |

    ### Housekeeping rules
    - New persistent rules must be placed in the correct file per this matrix. If unsure, ask. This prevents the previous disorganization.
    - Keep workspace root generally clean, including top-level directories. Treat it like your home directory, sorting and saving files in your folders.

    ## 8. Capability Self-Check (run on every new session)

    Before starting any task, run internally:
    "I am [main orchestrator OR sandboxed sub-agent]. My role is [orchestrator OR worker]. Writable paths: [list from section 3]. Allowed tools: [sandbox allow list from section 5, or everything minus deny list if main]. If this task requires tools outside my allow list, host changes, or writes outside allowed paths (as a sub-agent), reply exactly 'Delegate to main' and yield."

    ## 9. Installed Sandbox Packages
    ${installedPackages}

    ## Docs Query
    Unsure about OpenClaw CLI/backend/capability/syntax? `openclaw docs <query>` -> instant search /app/docs + web mirror.
  '';

  initialPersistent = ''
    ### Notes to Future Me
    - Keep this section concise and practical.
    - Record durable process improvements, not noisy logs.
  '';
}
