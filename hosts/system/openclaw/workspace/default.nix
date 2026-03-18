# Workspace document and task assembly.
# Single entry point for all workspace templates consumed by deployment.nix.
{
  lib,
  pkgs,
  agentDefs ? { },
  envSecrets ? { },
}:

let
  persistentMarker = "<!-- OPENCLAW-PERSISTENT-SECTION -->";

  persistentIntro = ''
    ${persistentMarker}

    ## Personal Evolution Section (Agent-owned)

    Below this line is yours to evolve. As you learn who you are and how you work best, update this section freely.

    If you need changes to the protected section above, ask the user to update the repository baseline.

  '';

  templateSrc = agentDefs.templateSrc or null;

  # ── Document templates ───────────────────────────────────────
  soul = import ./soul.nix { inherit templateSrc; };
  agents = import ./agents.nix { inherit lib envSecrets; };
  style = import ./style.nix;

  # ── Lobster workflow starters ────────────────────────────────
  taskTemplates = import ./tasks.nix { inherit pkgs; };

in
{
  inherit persistentMarker persistentIntro;

  documents = {
    "AGENTS.md" = agents;
    "SOUL.md" = soul;
    "STYLE.md" = style;
  };

  tasks = {
    templates = taskTemplates;
    tasksDir = "tasks";
  };
}
