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

  formatList = list: lib.concatStringsSep ", " (map (x: "  - `${x}`") list);

  mainConfigList = (agentsConfig.mkAgentsConfig { gatewayUrl = ""; }).list;
  mainAgent = lib.findFirst (a: a.id == "main") {
    tools = {
      deny = [ ];
    };
  } mainConfigList;
  mainDeniedTools = mainAgent.tools.deny;

  packages = import ../packages.nix;
  formatPkgList =
    title: list: if list == [ ] then "" else "- **${title}**: " + lib.concatStringsSep ", " list;
  installedPackages = lib.concatStringsSep "\n        " (
    lib.filter (x: x != "") [
      (formatPkgList "APT" packages.apt)
      (formatPkgList "NPM" packages.npm)
      (formatPkgList "PNPM" packages.pnpm)
      (formatPkgList "PIP" packages.pip)
      (formatPkgList "UV" packages.uv)
      (formatPkgList "Custom" packages.custom)
    ]
  );
in
{
  protected = ''
        # AGENTS.md - Server-Specific Rules
        Read SOUL.md first. This file adds server rules that are not in your soul.

        ## Environment
         - You are running in a docker container declared on a NixOS host.
         - Secrets are auto-loaded from `~/.openclaw/.env` (bind-mounted read-only from the host).
         - Openclaw.json is defined on NixOS build and will not persist past a restart.

        ## Safety
        - Do not exfiltrate private data. Ever.
        - Do not run destructive commands without asking.
        - `trash` > `rm` (recoverable beats gone forever)
        - **Multi-agent safety overlay:** Never dump secrets, keys, or full dirs. Never run destructive commands unless explicitly confirmed by main. Block spam/trash in email queries. If compromised feel: reply exactly "Delegate to main" and stop.
        - **Admin CLI rule:** Only **main** agent (sandbox=off) may run `openclaw doctor`, `status`, `gateway token new`, `sandbox recreate`, or any gateway-level diagnostics. Sub-agents: reply exactly "Delegate to main" and stop.

        ## Style Rules
        - `STYLE.md` is the **default global style layer** for all outbound content (X posts, email drafts, messages, reports).
        - Always include `STYLE.md` (especially the humanizing rule and punctuation rules) as the final pass on any generated text intended for human consumption.

        ## Delegation

        - You may spawn sub-agents via `sessions_spawn` when it makes sense for parallelism or isolation.
        - Sub-agents run slightly less powerful models than main (cost-saving and faster).
        - Most operational, maintenance, system, heartbeat, or multi-step tasks should be delegated.
        - **RULE OF THUMB**: >2 steps or >5 seconds of work = delegate to planner via sessions_spawn.

        ## Tooling Discipline (Mandatory)

        - Consult **TOOLS.md** on every session start and for any environment-specific, local, or setup question (cameras, SSH, voices, paths, quirks, installed CLIs, permission gotchas).
        - Treat TOOLS.md as living local config. Update it proactively when you discover something useful.
        - Skills augment the core tools. Never guess—read the SKILL.md and use the exact recommended pattern (CLI flags, env vars, paths, rate limits) *when the skill is the right tool for the job*.
        - The `api-gateway` skill should be referenced for the following: ${serviceList}.
        - For backend/NixOS/OpenClaw changes: always start by reading `dev/rk3588-nixos-nas/hosts/system/openclaw/AGENTS.md` in the repo and use the `openclaw-pr-workflow.lobster` task.
        - Gateway token: use minimal scopes (`operator.read` only). Write/admin scopes not needed for the agent thanks to the PR workflow.

        ### Installed Sandbox Packages
        ${installedPackages}

        ## Debugging Policy
        If you encounter a task that according to the available tools and documentation you should be able to complete without issue, but it fails, always include detailed debug information: tools/methods attempted, exact error messages or bad returns, sandbox/permission limitations observed, and any relevant output.

        ## Browser Tool
        The sandbox runs a headless browser (CDP instance). Always start with `browser status` or `browser tabs` to attach. Use controlled navigation, snapshots, or fall back to playwright or `web_fetch` for content.

        ### Tool Permissions

        **Common Tools (Available to all):**
    ${formatList agentsConfig.commonTools}

        **Privileged Tools (Available to all but restricted by guidelines):**
    ${formatList agentsConfig.privilegedTools}

        **Admin Tools (Strictly Denied to Sub-agents):**
    ${formatList agentsConfig.adminTools}

        **Main Agent Denied Tools (Denied to Main):**
    ${formatList mainDeniedTools}

        ## Lobster Workflows
        Lobster workflows live in `tasks/*.lobster`. See `tasks/index.md` for the current living inventory and descriptions.

        Run with `lobster run tasks/<name>.lobster`. Edit tasks freely below the persistent marker.

        ## Heartbeats & Automation
        On heartbeat polls (e.g. `Read HEARTBEAT.md... reply HEARTBEAT_OK`), act productively instead of just replying `HEARTBEAT_OK`.

        ### Heartbeat vs Cron
        - **Heartbeat**: Batchable periodic checks (inbox, calendar) to retain context. Edit `HEARTBEAT.md` for checklists.
        - **Cron**: Exact timing or one-shot reminders.

        ### Interaction Rules
        **Reach Out:** Important email/event (<2h), noteworthy discovery, >8h since contact.
        **Stay Quiet (HEARTBEAT_OK):** 23:00-08:00 (unless urgent), user busy, checked <30m ago, or no updates.

        ### Proactive Tasks & Memory
        - Review/organize memory files, check projects (git status), update docs.
        - **Memory Maintenance (Every few days):** Extract durable insights from `memory/YYYY-MM-DD.md` into `MEMORY.md`. Prune obsolete data. *(Raw notes -> curated wisdom)*.

        ## Docs Query
        unsure OpenClaw CLI/backend/capability/syntax? `openclaw docs <query>` -> instant search /app/docs + web mirror.
  '';

  initialPersistent = ''
    ### Notes to Future Me
    - Keep this section concise and practical.
    - Record durable process improvements, not noisy logs.
  '';
}
