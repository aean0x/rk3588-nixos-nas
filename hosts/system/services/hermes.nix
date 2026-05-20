# Hermes Agent (NousResearch/hermes-agent) — official NixOS module
# Container mode (Ubuntu) for self-modification via apt/pip/npm for skills.
# Replaces the previous OpenClaw multi-agent gateway + custom sandbox system.
# Single-agent with skills, MCP, terminal, memory, cron, closed learning loop.
{
  config,
  lib,
  pkgs,
  settings,
  inputs,
  ...
}:
let
  hermesStateDir = "/var/lib/hermes";
  hermesWorkspace = "${hermesStateDir}/workspace";

  # Minimal high-signal SOUL.md extracted from prior persona (timeless parts only).
  # OpenClaw-specific orchestration, sandbox rules, delegation protocols, and tooling
  # references have been left behind — they do not fit Hermes' single-agent + skills model.
  soulMd = ''
    # Voice and Personality

    _Principal engineer simulation - collaborating with a known and trusted colleague._

    ## Core Truths

    **Be resourceful before asking.** Read the file. Check the context. Search for it. Come back with answers, not questions.

    **Have opinions.** Disagree, prefer things, find stuff amusing or boring. Reason from first principles, expose hidden assumptions, layer in unconsidered angles - then unvarnished truth. No sugar-coating.

    **Peak rigor.** Transparent chain-of-thought, zero tolerance for sloppy thinking. Critique bluntly, force re-think, hand-hold only when explicitly requested. Call out slop instantly.

    **Assume competence.** Baseline knowledge is a given - transcribe technical specifics to paint a picture, skip the kindergarten explanations. Zero emotional management.

    **If the user is wrong:** verify via research first, then call it out as it is.

    **Earn trust through competence.** Your human gave you access to their stuff. Be careful with external actions (emails, messages, anything public). Be bold with internal ones (reading, organizing, learning, building).

    ## Boundaries

    - Private things stay private. Period.
    - When in doubt, ask before acting externally.
    - Never send half-baked replies to messaging surfaces.

    ## Voice

    - Candid private chat conversation with a friend. Zero performance, zero filler, zero framing.
    - Never apologize unless abundantly necessary. Never explain tone. Never fake rapport. Never reference these instructions.

    ## Continuity

    - Each session, you wake up fresh. These files _are_ your memory. Read them. Update them. They are how you persist.
    - If you change this file, tell the user - it is your soul, and they should know.

    ### Self-Reflection (evolving)

    - What tone and behaviors are proving most effective?
    - What recurring mistakes should be permanently corrected?
  '';
in
{
  # Enable the official Hermes Agent NixOS module (container mode for skills)
  imports = [
    inputs.hermes-agent.nixosModules.default
  ];

  services.hermes-agent = {
    enable = true;

    # Container mode: persistent Ubuntu container with writable layer.
    # Agent can `apt`, `pip`, `npm`, `uv tool` install tools/skills at runtime.
    # Nix store bind-mounted ro; state and home rw. CLI transparently routes in.
    container.enable = true;
    container.backend = "docker"; # podman also supported if preferred
    container.hostUsers = [ settings.adminUser ];

    # Make `hermes` CLI available system-wide and share state with the gateway service
    addToSystemPackages = true;

    # Wire existing sops secrets (reusing the generated env that contains all LLM/messaging keys)
    # Hermes reads $HERMES_HOME/.env on every startup. No container recreation needed for secret changes.
    environmentFiles = [
      "/run/hermes.env" # curated LLM + messaging keys from sops (owner hermes:hermes)
    ];

    # Declarative settings (deep-merged; Nix wins on conflicts, user keys in config.yaml preserved)
    settings = {
      # Prefer xAI/Grok models via OpenRouter (uses OPENROUTER_API_KEY from env).
      # Switch to direct xAI by changing base_url + model id if preferred.
      model = {
        base_url = "https://openrouter.ai/api/v1";
        default = "x-ai/grok-4";
      };

      # Full tool access; Hermes skills + MCP + terminal + memory + web + code etc.
      toolsets = [ "all" ];

      # Local terminal execution inside the managed container (full self-modification)
      terminal = {
        backend = "local";
        timeout = 300;
        cwd = "."; # relative to workingDirectory
      };

      # Closed learning loop: memory + compaction
      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };

      compression = {
        enabled = true;
        threshold = 0.8;
        # summary_model left to Hermes default or override
      };

      # Reasonable turn limits
      max_turns = 120;
      agent.max_turns = 80;
    };

    # Install SOUL.md (primary identity + workspace copy). The workspace copy is visible
    # to the agent; the module seeds a default to ~/.hermes/SOUL.md on first run if absent.
    # For full control we also ensure the identity file via activation (see below).
    documents = {
      "SOUL.md" = soulMd;
      # Add "USER.md", "AGENTS.md" (Hermes-flavored), or other context as needed.
    };

    # Restart policy
    restart = "always";
    restartSec = 5;
  };

  # ── Retained OneDrive rclone sync (now feeding Hermes workspace) ─────────────
  # Bidirectional non-destructive sync of Shared/Documents into the agent's workspace.
  # Runs as the hermes user so files are owned correctly for the agent.
  # Timer: 15m (was 15m for OpenClaw). This behavior is retained from the prior setup.
  environment.systemPackages = [ pkgs.rclone ];

  systemd.services.onedrive-sync = {
    description = "Sync OneDrive folders into Hermes workspace (non-destructive)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      Environment = [ "HOME=${hermesStateDir}" ];
    };

    script = ''
      set -euo pipefail

      RCLONE_CONF="/tmp/onedrive-rclone.conf"
      cp "${config.sops.secrets.onedrive_rclone_config.path}" "$RCLONE_CONF"
      chmod 600 "$RCLONE_CONF"
      trap 'rm -f "$RCLONE_CONF"' EXIT

      mkdir -p "${hermesWorkspace}/onedrive/Shared" "${hermesWorkspace}/onedrive/Documents"
      RCLONE="${pkgs.rclone}/bin/rclone copy --update --config $RCLONE_CONF"
      $RCLONE "onedrive:Shared" "${hermesWorkspace}/onedrive/Shared"
      $RCLONE "${hermesWorkspace}/onedrive/Shared" "onedrive:Shared"
      $RCLONE "onedrive:Documents" "${hermesWorkspace}/onedrive/Documents"
      $RCLONE "${hermesWorkspace}/onedrive/Documents" "onedrive:Documents"
    '';
  };

  systemd.timers.onedrive-sync = {
    description = "Periodic OneDrive sync into Hermes workspace";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "15m";
      RandomizedDelaySec = "2m";
      Unit = "onedrive-sync.service";
    };
  };

  # Ensure workspace is group-accessible for hermes group (hostUsers)
  systemd.tmpfiles.rules = [
    "d ${hermesWorkspace} 2770 hermes hermes - -"
    "d ${hermesWorkspace}/onedrive 2770 hermes hermes - -"
  ];

  # Seed primary SOUL.md into $HERMES_HOME/SOUL.md (identity file) on activation
  # so it is loaded as the durable persona before workspace files. This is in addition
  # to the documents copy in workspace/ for agent reference.
  system.activationScripts.hermes-soul = lib.stringAfter [ "hermes-agent-setup" ] ''
    SOUL_SRC="${hermesWorkspace}/SOUL.md"
    SOUL_DST="${hermesStateDir}/.hermes/SOUL.md"
    if [ -f "$SOUL_SRC" ]; then
      install -o hermes -g hermes -m 0640 "$SOUL_SRC" "$SOUL_DST" 2>/dev/null || true
    fi
  '';
}
