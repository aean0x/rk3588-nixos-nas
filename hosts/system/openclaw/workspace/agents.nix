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

  mainConfigList = (agentsConfig.mkAgentsConfig { gatewayUrl = ""; }).list;
  mainAgent = lib.findFirst (a: a.id == "main") {
    tools = {
      deny = [ ];
    };
  } mainConfigList;
  mainDeniedTools = mainAgent.tools.deny;

  deps = (import ../packages.nix { inherit lib; }).dependencies;
  byType = type: lib.filter (s: (s.type or "custom") == type) deps;
  aptPkgs = lib.concatMap (s: s.packages or [ ]) (byType "apt");
  npmPkgs = map (s: s.package or s.name) (byType "npm");
  pnpmPkgs = map (s: s.package or s.name) (byType "pnpm");
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

    You are running in the standard OpenClaw orchestrator layout:
    - **Main** = orchestrator (broad tools, no sandbox). You may (and should) spawn sub-agents via `sessions_spawn` whenever it makes sense for parallelism, isolation, or when a task is >2 steps or >5s of work.
    - **Sub-agents** = workers (sandboxed, restricted tools, ephemeral container, slightly less powerful model).
    - **Delegation rule (main only):** >2 steps or >5s of work = spawn via `sessions_spawn`.
    - **Handoff:** Use `sessions_yield` or `sessions_send` when done. Never assume the other side is waiting.
    - Never spawn from a sub-agent unless the task *explicitly* requires nesting (max depth 2).

    ### Lobster Workflows
    Lobster workflows live in `tasks/*.lobster`. See `tasks/index.md` for the current living inventory and descriptions.
    Run with `lobster run tasks/<name>.lobster`. Edit tasks freely below the persistent marker.

    ## 3. Sandbox Filesystem Boundaries (readOnlyRoot = true)

    The container root filesystem is immutable. Sub-agents can **only** write to the locations below. Anything else will fail with a read-only filesystem error. (Main agent has no such restriction.)

    **Writable (tmpfs — in-memory, cleared on sandbox restart):**
    ${formatPathList agentsConfig.sandboxWritable.tmpfs}

    **Writable (persistent across restarts and redeploys):**
    ${formatPathList agentsConfig.sandboxWritable.persistent}

    **Everything else is read-only.**
    Use workspace/ for scripts, venvs, node_modules, memory files, etc. Never try to write to /usr, /home/node outside the allowed subdirs, or any other path.

    ## 4. Runtime Package Management Rules

    - **Python venvs** — create inside `workspace/venvs/<name>/` (or `/tmp/venv-<pid>/` for one-shot). System Python packages are baked into the image via uv; never run `pip install` at runtime.
    - **Node / pnpm** — prefer `workspace/node_modules` or `workspace/.pnpm-store`. Global packages are baked into the image (see section 8).
    - **Never** run `apt`, `npm install -g`, `pip install --system`, or any package manager that touches the read-only root.
    - Need a package that isn't installed? Delegate to main — it requires a NixOS rebuild.

    ## 5. Tooling Discipline

    - Consult **TOOLS.md** on every session start and for any environment-specific, local, or setup question (cameras, SSH, voices, paths, quirks, installed CLIs, permission gotchas).
    - Treat TOOLS.md as living local config. Update it proactively when you discover something useful.
    - Skills augment the core tools. Never guess — read the SKILL.md and use the exact recommended pattern (CLI flags, env vars, paths, rate limits) *when the skill is the right tool for the job*.
    - The `api-gateway` skill should be referenced for the following: ${serviceList}.
    - For backend/NixOS/OpenClaw changes: always start by reading `dev/rk3588-nixos-nas/hosts/system/openclaw/AGENTS.md` in the repo and use the `openclaw-pr-workflow.lobster` task.
    - Gateway token: use minimal scopes (`operator.read` only). Write/admin scopes not needed for the agent thanks to the PR workflow.
    - `STYLE.md` is the **default global style layer** for all outbound content. Always apply it as the final pass on any generated text intended for human consumption.

    ### Tool Permissions

    **Common Tools (Available to all):**
    ${formatList agentsConfig.commonTools}

    **Privileged Tools (Available to all but restricted by guidelines):**
    ${formatList agentsConfig.privilegedTools}

    **Admin Tools (Strictly Denied to Sub-agents):**
    ${formatList agentsConfig.adminTools}

    **Main Agent Denied Tools (Denied to Main):**
    ${formatList mainDeniedTools}

    ### Browser Tool
    The sandbox runs a headless browser (CDP instance). Always start with `browser status` or `browser tabs` to attach. Use controlled navigation, snapshots, or fall back to playwright or `web_fetch` for content.

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

    ## 7. Capability Self-Check (run on every new session)

    Before starting any task, run internally:
    "I am [main orchestrator OR sandboxed sub-agent]. My role is [orchestrator OR worker]. Writable paths: [list from section 3]. Allowed tools: [common + privileged from section 5]. If this task requires admin tools, host changes, or writes outside allowed paths (as a sub-agent), reply exactly 'Delegate to main' and yield."

    ## 8. Installed Sandbox Packages
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
