# OpenClaw agent definitions - imports shenhao-stu/openclaw-agents manifest.
# Agent IDs and roles come from the pinned repo's agents.yaml.
# Tool policies, sandbox secrets, and JSON config generation are layered on here.
#
# Structure:
#   1. YAML import & shared defaults (tools, workspace templates)
#   2. Per-agent override dicts
#   3. mkAgent config builder + tool summary generator
{
  pkgs,
  lib,
  openclaw-agents,
}:
let
  env = name: "\${${name}}";
  hostWorkspace = "/home/node/.openclaw/workspace";

  # ── YAML Import ────────────────────────────────────────────
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  agentsJson = pkgs.runCommand "openclaw-agents-json" { nativeBuildInputs = [ python ]; } ''
        python3 -c "
    import yaml, json, sys
    raw = open('${openclaw-agents}/agents.yaml', 'rb').read().decode('utf-8', errors='replace')
    data = yaml.safe_load(raw)
    json.dump(data, sys.stdout, ensure_ascii=False)
    " > $out
  '';
  manifest = builtins.fromJSON (builtins.readFile agentsJson);
  allAgents = manifest.agents;
  subAgentList = builtins.filter (a: a.id != "main") allAgents;
  subAgentIds = map (a: a.id) subAgentList;

  # ── Agent display name (strip emoji prefix) ───────────────
  agentName =
    a:
    let
      parts = lib.splitString " " a.name;
    in
    if builtins.length parts > 1 then builtins.elemAt parts 1 else a.name;

  # ── Tool Policy ────────────────────────────────────────────
  # Strategy: profile "full" gives every tool. tools.deny removes what's not needed.
  # tools.allow is NOT used — it's an exclusive whitelist that replaces the profile.
  #
  # Three tiers:
  #   1. Common tools — every sub-agent gets these (not listed, implied by profile "full")
  #   2. Privileged tools — denied by default, granted per-agent via grantPrivileged
  #   3. Admin tools — denied from ALL sub-agents unconditionally

  # prettier-ignore
  commonTools = [
    "read"
    "write"
    "edit"
    "web_search"
    "web_fetch"
    "browser"
    "image"
    "memory_search"
    "memory_get"
    "agents_list"
    "session_status"
    "tts"
    "pdf"
    "sessions_list"
    "sessions_history"
    "sessions_send"
    "sessions_yield"
  ];

  # prettier-ignore
  adminTools = [
    "cron"
    "gateway"
    "nodes"
    "message"
    "canvas"
  ];

  # prettier-ignore
  privilegedTools = [
    "exec"
    "apply_patch"
    "process"
    "sessions_spawn"
    "subagents"
  ];

  # Secrets every sub-agent gets (gateway token is injected separately in mkAgent).
  defaultSecrets = {
    BRAVE_API_KEY = env "BRAVE_API_KEY";
    GOOGLE_PLACES_API_KEY = env "GOOGLE_PLACES_API_KEY";
    BROWSERLESS_API_TOKEN = env "BROWSERLESS_API_TOKEN";
  };

  defaultOverrides = {
    grantPrivileged = [ ];
    extraDeny = [ ];
    extraSecrets = { };
    agentsMdBlurb = null;
  };

  # ── Main Agent Config ─────────────────────────────────────
  mainTools = {
    profile = "full";
    deny = [
      "group:web"
      "group:messaging"
      "group:ui"
    ];
  };

  # ── Per-Agent Overrides ────────────────────────────────────
  # grantPrivileged: which privileged tools this agent gets (removed from deny list).
  # extraDeny: additional tools to deny beyond the defaults.
  agentOverrides = {
    planner = {
      grantPrivileged = [
        "exec"
        "apply_patch"
        "process"
        "sessions_spawn"
        "subagents"
      ];
    };
    ideator = { };
    critic = { };
    surveyor = {
      grantPrivileged = [ "exec" ];
    };
    coder = {
      grantPrivileged = [
        "exec"
        "apply_patch"
        "process"
      ];
    };
    writer = {
      grantPrivileged = [
        "exec"
        "apply_patch"
        "process"
      ];
    };
    reviewer = {
      grantPrivileged = [
        "exec"
        "process"
      ];
    };
    scout = {
      grantPrivileged = [
        "exec"
        "process"
      ];
    };
  };

  resolveOverrides = id: defaultOverrides // (agentOverrides.${id} or { });

  # Build deny list: adminTools + (privilegedTools minus granted) + extraDeny
  mkDenyList =
    ovr:
    let
      granted = ovr.grantPrivileged or [ ];
    in
    adminTools ++ (lib.subtractLists granted privilegedTools) ++ (ovr.extraDeny or [ ]);

  # ── Tool Summary (for AGENTS.md blurb injection) ───────────
  mkToolSummary =
    id:
    let
      ovr = resolveOverrides id;
      granted = ovr.grantPrivileged or [ ];
      denyList = mkDenyList ovr;
      allSecretNames = lib.attrNames (defaultSecrets // ovr.extraSecrets);
      grantedLine =
        if granted == [ ] then
          "  - **Granted (privileged):** none"
        else
          "  - **Granted (privileged):** ${lib.concatStringsSep ", " granted}";
      denyLine = "  - **Denied:** ${lib.concatStringsSep ", " denyList}";
      secretsLine = "  - **Secrets:** ${lib.concatStringsSep ", " allSecretNames}";
    in
    ''
      ## Your Permissions
      - **Common tools:** ${lib.concatStringsSep ", " commonTools}
      ${grantedLine}
      ${denyLine}
      ${secretsLine}
    '';

  # ── Sub-Agent Workspace Templates ──────────────────────────
  subAgentWorkspace = {
    persistentMarker = "<!-- OPENCLAW-PERSISTENT-SECTION -->";
    persistentIntro = ''
      <!-- OPENCLAW-PERSISTENT-SECTION -->

      ## Personal Evolution Section (Agent-owned)

      Below this line is yours to evolve. As you learn who you are and how you work best, update this section freely.

      If you need changes to the protected section above, ask the user to update the repository baseline.

    '';
    documents = {
      "AGENTS.md" = {
        protected = ''
          ## Language: English Only
          All output in American English. Chinese in source files is reference content only. Apply STYLE.md rules to every message.

          ## Environment Context
          - You are a sub-agent running in a Docker sandbox.
          - For dangerous admin commands (`openclaw doctor`, gateway restart, sandbox config changes, secret rotation), reply exactly "Delegate to main" and stop. Safe read-only commands (status checks, log tailing, file reads) are fine to run locally.
          - Skills are shared from main, mounted read-only from `/home/node/.openclaw/workspace/skills`.
          - `dev/` is mounted rw for shared coding projects.
          - `.tools` is ro mounted and in PATH for common utilities (uv, docker, goplaces, bird, etc).
          - `/dropbox` is a shared rw mount for inter-agent file exchange.
          - Your tool set is defined in openclaw.json and summarized below.
        '';
        initialPersistent = ''
          ### Notes to Future Me
          - Keep this section concise and practical.
          - Record durable process improvements, not noisy logs.
        '';
      };
    };
  };

  # ── mkAgent: Build JSON config entry for a sub-agent ───────
  mkAgent =
    { workspace, gatewayUrl }:
    a:
    let
      ovr = resolveOverrides a.id;
      denyList = mkDenyList ovr;
    in
    {
      id = a.id;
      workspace = "${workspace}/.agents/${a.id}";
      identity.name = agentName a;
      sandbox = {
        workspaceAccess = "rw";
        docker = {
          network = "bridge";
          setupCommand = "export PATH=\"${workspace}/.tools:\$PATH\"";
          binds = [
            "${hostWorkspace}/skills:${workspace}/.agents/${a.id}/skills:ro"
            "${hostWorkspace}/.tools:${workspace}/.tools:ro"
            "${hostWorkspace}/dev:${workspace}/dev:rw"
            "${hostWorkspace}/dropbox:/dropbox:rw"
          ];
          env =
            defaultSecrets
            // ovr.extraSecrets
            // {
              OPENCLAW_GATEWAY_TOKEN = env "OPENCLAW_GATEWAY_TOKEN";
              OPENCLAW_GATEWAY_URL = gatewayUrl;
            };
        };
      };
      tools = {
        profile = "full";
        deny = denyList;
      };
    };

in
{
  inherit
    commonTools
    adminTools
    privilegedTools
    defaultSecrets
    subAgentList
    subAgentIds
    subAgentWorkspace
    agentOverrides
    resolveOverrides
    mkToolSummary
    mkDenyList
    ;
  templateSrc = openclaw-agents;

  mkJsonConfig =
    { workspace, gatewayUrl }:
    let
      mainDef = {
        id = "main";
        subagents.allowAgents = [ "*" ];
        sandbox.mode = "off";
        tools = mainTools;
      };
    in
    [ mainDef ] ++ (map (mkAgent { inherit workspace gatewayUrl; }) subAgentList);
}
