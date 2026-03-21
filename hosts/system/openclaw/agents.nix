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

  # ── Tool Defaults ──────────────────────────────────────────
  # Baseline tools every sub-agent gets. Per-agent extraAllow merges on top.
  # prettier-ignore
  defaultTools = [
    "read"
    "write"
    "edit"
    "sessions_list"
    "sessions_history"
    "sessions_send"
    "lobster"
    "group:memory"
    "group:fs"
    "browser"
  ];

  # Secrets every sub-agent gets (gateway token is injected separately in mkAgent).
  defaultSecrets = {
    BRAVE_API_KEY = env "BRAVE_API_KEY";
    GOOGLE_PLACES_API_KEY = env "GOOGLE_PLACES_API_KEY";
    BROWSERLESS_API_TOKEN = env "BROWSERLESS_API_TOKEN";
  };

  defaultOverrides = {
    extraAllow = [ ];
    extraSecrets = { };
    agentsMdBlurb = null;
  };

  # ── Main Agent Config ─────────────────────────────────────
  # PERMISSIONS DISABLED — all tool restrictions commented out while debugging sandbox tools.
  # Re-enable once sub-agents confirmed to have full tool access.
  mainTools = {
    profile = "full";
    # deny = [ "group:web" "group:messaging" "group:ui" ];
  };

  # ── Per-Agent Overrides ────────────────────────────────────
  # extraAllow merges with defaultTools for documentation purposes.
  # Tool restrictions are currently disabled for debugging.
  agentOverrides = {
    planner = {
      extraAllow = [
        "exec"
        "apply_patch"
        "sessions_spawn"
      ];
    };
    ideator = { };
    critic = { };
    surveyor = {
      extraAllow = [ "exec" ];
    };
    coder = {
      extraAllow = [
        "exec"
        "apply_patch"
      ];
    };
    writer = {
      extraAllow = [
        "exec"
        "apply_patch"
      ];
    };
    reviewer = {
      extraAllow = [ "exec" ];
    };
    scout = {
      extraAllow = [ "exec" ];
    };
  };

  resolveOverrides = id: defaultOverrides // (agentOverrides.${id} or { });

  # ── Tool Summary (for AGENTS.md blurb injection) ───────────
  mkToolSummary =
    id:
    let
      ovr = resolveOverrides id;
      extras = ovr.extraAllow;
      allSecretNames = lib.attrNames (defaultSecrets // ovr.extraSecrets);
      extrasLine =
        if extras == [ ] then
          "  - **Extra tools:** none (baseline only)"
        else
          "  - **Extra tools:** ${lib.concatStringsSep ", " extras}";
      secretsLine = "  - **Secrets:** ${lib.concatStringsSep ", " allSecretNames}";
    in
    ''
      ## Your Permissions
      - **Baseline:** ${lib.concatStringsSep ", " defaultTools}
      ${extrasLine}
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
          - `.tools` is ro mounted and in PATH for common utilities (uv, docker, goplaces, bird, etc).
          - Your tool allowlist is defined in openclaw.json and summarized below.
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
  # PERMISSIONS DISABLED — no tools.allow or tools.deny emitted.
  # Sub-agents inherit global profile only. Re-enable per-agent restrictions
  # once sandbox tool provisioning is confirmed working.
  mkAgent =
    { workspace, gatewayUrl }:
    a:
    let
      ovr = resolveOverrides a.id;
      # allowList = lib.unique (defaultTools ++ ovr.extraAllow);
    in
    {
      id = a.id;
      workspace = "${workspace}/.agents/${a.id}";
      identity.name = agentName a;
      memorySearch.enabled = false;
      sandbox = {
        workspaceAccess = "rw";
        docker = {
          network = "bridge";
          setupCommand = "export PATH=\"${workspace}/.tools:\$PATH\"";
          binds = [
            "${hostWorkspace}/skills:${workspace}/.agents/${a.id}/skills:ro"
            "${hostWorkspace}/.tools:${workspace}/.tools:ro"
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
      # tools = {
      #   profile = "full";
      #   allow = allowList;
      # };
    };

in
{
  inherit
    defaultTools
    defaultSecrets
    subAgentList
    subAgentIds
    subAgentWorkspace
    agentOverrides
    resolveOverrides
    mkToolSummary
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
