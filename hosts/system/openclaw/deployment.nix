{
  config,
  pkgs,
  lib,
  settings,
  inputs,
  ...
}:
let
  cfg = config.services.openclaw;
  openclawConfig = import ./config.nix {
    inherit pkgs lib settings;
    openclaw-agents = inputs.openclaw-agents;
  };
  agentDefs = openclawConfig.agentDefs;
  workspaceDefs = import ./workspace.nix {
    inherit lib agentDefs;
    envSecrets = cfg.envSecrets;
  };

  openclawTasks = import ./tasks.nix { inherit lib pkgs; };

  baseImage = "ghcr.io/phioranex/openclaw-docker:latest";
  configDir = "/var/lib/openclaw";
  workspaceDir = "${configDir}/workspace";
  subAgentsDir = "${workspaceDir}/.agents";
  tasksDir = "${workspaceDir}/tasks";

  envFileScript = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      envVar: secretPath: ''echo "${envVar}=$(cat ${secretPath})" >> /run/openclaw.env''
    ) cfg.envSecrets
  );

  # ── Main agent workspace files ─────────────────────────────
  persistentIntroFile = pkgs.writeText "persistent-intro" workspaceDefs.persistentIntro;
  workspaceDocs = lib.mapAttrs (
    name: doc: pkgs.writeText "${name}-protected" doc.protected
  ) workspaceDefs.documents;
  workspaceDefaults = lib.mapAttrs (
    name: doc: pkgs.writeText "${name}-default" doc.initialPersistent
  ) workspaceDefs.documents;

  # ── Shenhao template source ────────────────────────────────
  templateSrc = agentDefs.templateSrc;
  workflowDir = "${templateSrc}/.agents/workflows";

  subAgentPersistentIntroFile = pkgs.writeText "subagent-persistent-intro" agentDefs.subAgentWorkspace.persistentIntro;
  subAgentAgentsDefault =
    pkgs.writeText "subagent-agents-default"
      agentDefs.subAgentWorkspace.documents."AGENTS.md".initialPersistent;

  # Per-agent AGENTS.md protected sections (shared base + optional blurb)
  baseProtected = agentDefs.subAgentWorkspace.documents."AGENTS.md".protected;
  subAgentAgentsProtectedFor =
    id:
    let
      ovr = agentDefs.resolveOverrides id;
      blurb = if ovr.agentsMdBlurb != null then "\n${ovr.agentsMdBlurb}" else "";
    in
    pkgs.writeText "${id}-agents-protected" (baseProtected + blurb);

  # STYLE.md deployed to each sub-agent (our formatting/language rules)
  styleFile = workspaceDocs."STYLE.md";

  # ── Sub-agent deployment (replicates setup.sh end state) ───
  subAgentSetup = lib.concatStringsSep "\n" (
    map (id: ''
      # ── ${id} ──
      agent_dir="${subAgentsDir}/${id}"
      mkdir -p "$agent_dir/memory"

      # Deploy per-agent identity files directly (setup.sh end state after BOOTSTRAP merge)
      cp "${templateSrc}/.agents/${id}/soul.md" "$agent_dir/SOUL.md"
      cp "${templateSrc}/.agents/${id}/user.md" "$agent_dir/USER.md"
      # STYLE.md - our formatting and language rules
      cp "${styleFile}" "$agent_dir/STYLE.md"

      # AGENTS.md: Protected (with per-agent blurb) + Workflows + Agent Persistent workspace
      tmp_protected="$agent_dir/AGENTS.md.protected"
      cat "${subAgentAgentsProtectedFor id}" > "$tmp_protected"
      echo "" >> "$tmp_protected"
      echo "---" >> "$tmp_protected"
      echo "# Workflow Reference for ${id}" >> "$tmp_protected"
      echo "" >> "$tmp_protected"
      case "${id}" in
        planner)
          for wf in paper-pipeline brainstorm rebuttal daily-digest; do
            [ -f "${workflowDir}/$wf.md" ] && { echo "---" >> "$tmp_protected"; cat "${workflowDir}/$wf.md" >> "$tmp_protected"; }
          done ;;
        ideator|critic)
          for wf in brainstorm paper-pipeline; do
            [ -f "${workflowDir}/$wf.md" ] && { echo "---" >> "$tmp_protected"; cat "${workflowDir}/$wf.md" >> "$tmp_protected"; }
          done ;;
        surveyor)
          for wf in brainstorm paper-pipeline rebuttal; do
            [ -f "${workflowDir}/$wf.md" ] && { echo "---" >> "$tmp_protected"; cat "${workflowDir}/$wf.md" >> "$tmp_protected"; }
          done ;;
        coder|writer|reviewer)
          for wf in paper-pipeline rebuttal; do
            [ -f "${workflowDir}/$wf.md" ] && { echo "---" >> "$tmp_protected"; cat "${workflowDir}/$wf.md" >> "$tmp_protected"; }
          done ;;
        scout)
          for wf in daily-digest paper-pipeline brainstorm; do
            [ -f "${workflowDir}/$wf.md" ] && { echo "---" >> "$tmp_protected"; cat "${workflowDir}/$wf.md" >> "$tmp_protected"; }
          done ;;
      esac

      update_doc_custom "$agent_dir/AGENTS.md" "$tmp_protected" "${subAgentAgentsDefault}" "${subAgentPersistentIntroFile}" "${agentDefs.subAgentWorkspace.persistentMarker}"
      rm -f "$tmp_protected"

      chown -R 1000:1000 "$agent_dir"
    '') agentDefs.subAgentIds
  );

  dockerGid =
    if (config.users.groups ? docker && config.users.groups.docker.gid != null) then
      config.users.groups.docker.gid
    else
      131;
in
{
  config = {

    systemd.services.docker-openclaw-gateway.serviceConfig = {
      Restart = pkgs.lib.mkForce "always";
      RestartSec = "5s";
    };

    systemd.services.openclaw-setup = {
      description = "Deploy OpenClaw config and secrets";
      wantedBy = [ "multi-user.target" ];
      before = [ "docker-openclaw-gateway.service" ];
      requiredBy = [ "docker-openclaw-gateway.service" ];
      after = [
        "sops-nix.service"
        "openclaw-builder.service"
      ];
      requires = [ "openclaw-builder.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        mkdir -p ${configDir} ${workspaceDir}/memory ${workspaceDir}/skills ${subAgentsDir}

        # Protected+persistent doc assembly
        update_doc_custom() {
          local target="$1"
          local protected_path="$2"
          local default_persistent_path="$3"
          local intro_path="$4"
          local marker="$5"
          local separator=$'\n\n---\n\n'

          if [ -f "$target" ] && grep -Fq "$marker" "$target"; then
             sed -n "/$marker/,\$p" "$target" > "$target.persistent"
          else
             cat "$intro_path" "$default_persistent_path" > "$target.persistent"
          fi

          cat "$protected_path" > "$target.tmp"
          echo "$separator" >> "$target.tmp"
          cat "$target.persistent" >> "$target.tmp"

          mv "$target.tmp" "$target"
          rm -f "$target.persistent"
          chown 1000:1000 "$target"
          chmod 0640 "$target"
        }

        update_doc() {
          update_doc_custom "${workspaceDir}/$1" "$2" "$3" "${persistentIntroFile}" "${workspaceDefs.persistentMarker}"
        }

        update_doc "AGENTS.md" "${workspaceDocs."AGENTS.md"}" "${workspaceDefaults."AGENTS.md"}"
        update_doc "SOUL.md"   "${workspaceDocs."SOUL.md"}"   "${workspaceDefaults."SOUL.md"}"
        update_doc "STYLE.md"  "${workspaceDocs."STYLE.md"}"  "${workspaceDefaults."STYLE.md"}"

        # Sub-agent workspaces
        ${subAgentSetup}

        # Lobster tasks deployment
        mkdir -p "${tasksDir}"
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: file: ''
            cp ${file} "${tasksDir}/${name}"
          '') openclawTasks.templates
        )}
        chown -R 1000:1000 "${tasksDir}"

        # Own everything under configDir before writing the config file
        chown -R 1000:1000 ${configDir}
        chmod -R 700 ${configDir}

        # openclaw.json
        CONFIG_FILE="${configDir}/openclaw.json"
        cp ${openclawConfig.configFile} "$CONFIG_FILE"
        chown 1000:${toString dockerGid} "$CONFIG_FILE"
        chmod 0660 "$CONFIG_FILE"

        # Environment file
        rm -f /run/openclaw.env
        touch /run/openclaw.env
        chmod 0640 /run/openclaw.env
        ${envFileScript}
      '';
    };

    # Weekly image refresh
    systemd.services.openclaw-refresh = {
      description = "Pull latest OpenClaw image and rebuild custom image";
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.docker}/bin/docker pull ${baseImage} || true
        ${pkgs.docker}/bin/docker image prune -f --filter "until=168h"
        ${pkgs.systemd}/bin/systemctl restart openclaw-builder.service
        ${pkgs.systemd}/bin/systemctl try-restart docker-openclaw-gateway.service
      '';
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
    };

    systemd.timers.openclaw-refresh = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon 04:00:00";
        Persistent = true;
        RandomizedDelaySec = "3600";
      };
    };
  };
}
