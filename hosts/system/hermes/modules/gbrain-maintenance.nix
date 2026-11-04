# GBrain maintenance window - the carrier for the brain's own doctor.
#
# `gbrain serve --http` is the sole PGLite writer on this host and runs no
# maintenance cycle: the doctor fails `sync_freshness` at 72 h and warns on
# `links_extraction_lag` / `extract_atoms_backlog` whenever nobody syncs by hand.
# Nothing in the agent jail can do it, and the MCP route cannot either:
# `serve --http` enqueues Minion jobs but starts no worker, so a submitted
# job sits `waiting` forever (minion job 1 was created 2026-10-04 and cancelled
# seven minutes later with attempts_started = 0). The one sanctioned window is
# with the serve stopped, CLI as sole writer.
#
# The jail cannot use that window: the CLI's `probeLivePgliteHolder` gate is a
# PID-liveness probe, the jail shares the filesystem but not the PID namespace,
# so from there the live serve reads as dead and the CLI takes the LOCAL path as
# a second writer (WAL repair 2026-10-01T03:03Z). On the host the same probe is
# correct, which is exactly why this unit belongs here and not in a cron job.
#
# This unit is that window: daily, stop gbrain-mcp-http, auto-upgrade the CLI,
# release a pre-activation writer claim, sync every registered source and run
# the extraction phases the doctor asks for as the serve's own user (same HOME,
# same /run/hermes.env, same embedding pins), then bring it back. The restart is
# in an EXIT trap, and the unit refuses to touch the data dir if the serve did
# not actually stop, so a failure can neither strand the brain MCP offline nor
# open a second writer.
#
#   sync_freshness        -> gbrain sync --source <every source> --no-pull
#   links_extraction_lag  -> gbrain extract --stale
#   extract_atoms_backlog -> gbrain dream --phase extract_atoms --drain
#   last_full_cycle_at    -> gbrain dream --source <every source>
#
# The freshness gates are per source, so the registry (`sources list --json`)
# decides what the window touches: a source left out keeps its stamp and fails
# `sync_freshness` at 72 h. A registry read that returns nothing aborts the
# window instead of reporting a blind run green. `dream --source <id>` is also
# per source: a named non-default source only gets the deterministic freshness
# phases that way, while default runs the full cycle that stamps
# `last_full_cycle_at`.
#
# `dream --phase extract_atoms --drain` exits 3 when the window closed before
# the backlog emptied: that is "run again", not a failure - the next window
# continues it and the run stays green.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = config.services.hermes-agent;
  gbrainCfg = config.services.hermesPnP.gbrain;
  userHome = "${agent.stateDir}/home";
  gbrainBin = "${userHome}/.bun/bin/gbrain";
  hostPath = "${userHome}/.bun/bin:${userHome}/.local/bin:/run/current-system/sw/bin:/usr/bin:/bin";

  maintenance = pkgs.writeShellApplication {
    name = "gbrain-maintenance";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      # The writer-status and sources-list gates parse the CLI's --json output.
      pkgs.python3
    ];
    text = ''
      systemctl=${config.systemd.package}/bin/systemctl
      gbrain=${gbrainBin}
      serve="gbrain-mcp-http.service"
      source_id=default
      run_as=${agent.user}
      home=${userHome}
      host_path=${hostPath}

      if [ ! -x "$gbrain" ]; then
        echo "gbrain-maintenance: $gbrain is not executable - CLI bootstrap pending, nothing to do" >&2
        exit 0
      fi

      # The serve is the sole PGLite writer: maintenance runs only while it is
      # down. `systemctl stop` returns once the unit is inactive, i.e. the
      # PGLite handle is closed - never background it.
      was_up=no
      if "$systemctl" is-active --quiet "$serve"; then was_up=yes; fi

      # Invoked by the EXIT trap below. Shellcheck does not see that call.
      # shellcheck disable=SC2329
      restore_serve() {
        if [ "$was_up" = yes ]; then
          "$systemctl" start "$serve" ||
            echo "gbrain-maintenance: could not restart $serve - start it by hand" >&2
        fi
      }
      trap restore_serve EXIT

      "$systemctl" stop "$serve" || true
      if "$systemctl" is-active --quiet "$serve"; then
        echo "gbrain-maintenance: $serve still active after stop - refusing to run a second writer" >&2
        exit 1
      fi

      # -p keeps the unit's EnvironmentFile values (model keys, embedding pins);
      # HOME is overridden to the serve's own so the CLI resolves the same brain
      # and writes as the same user.
      run_gbrain() {
        runuser -u "$run_as" --preserve-environment -- \
          env HOME="$home" PATH="$host_path" "$gbrain" "$@"
      }

      # latest-stable only. Autopilot is a second PGLite writer, so this
      # window is the auto-upgrade. Exit 78 means the Nix Bun is too old;
      # the installed CLI still runs the rest of the window.
      rc=0
      echo "gbrain-maintenance: upgrade --no-autopilot-install"
      upgrade_rc=0
      run_gbrain upgrade --no-autopilot-install || upgrade_rc=$?
      if [ "$upgrade_rc" -eq 78 ]; then
        echo "gbrain-maintenance: upgrade needs a newer Bun (rc=78) - staying on the installed CLI" >&2
      elif [ "$upgrade_rc" -ne 0 ]; then
        echo "gbrain-maintenance: upgrade failed rc=$upgrade_rc" >&2
        rc=1
      fi

      # Claimed, but persistence was never activated: classic sync refuses
      # with writer_coordinator_required. Release that claim. A managed
      # brain (enabled, or mode managed) is left alone.
      echo "gbrain-maintenance: writer status"
      writer_json=$(run_gbrain sources writer status --json || true)
      release=$(printf '%s\n' "$writer_json" | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    raise SystemExit(0)
data = json.loads(raw[start:])
if data.get("enabled") is True or data.get("mode") == "managed":
    raise SystemExit(0)
sources = ((data.get("onboarding") or {}).get("sources") or [])
if any(item.get("state") == "activation_required" for item in sources):
    print("release")
' || true)
      apply=
      if [ "$release" = "release" ]; then
        echo "gbrain-maintenance: release pre-activation claim"
        preview=$(run_gbrain sources writer deactivate --dry-run --json || true)
        if ! apply=$(printf '%s\n' "$preview" | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    raise SystemExit(1)
data = json.loads(raw[start:])
if data.get("blockers"):
    raise SystemExit(1)
cmd = data.get("apply_command") or ""
prefix = "gbrain "
if not cmd.startswith(prefix):
    raise SystemExit(1)
print(cmd[len(prefix):])
'); then
          echo "gbrain-maintenance: pre-activation release is blocked" >&2
          rc=1
          apply=
        fi
      fi
      if [ -n "$apply" ]; then
        read -r -a apply_args <<< "$apply"
        run_gbrain "''${apply_args[@]}" || rc=1
      fi

      # Doctor's freshness gates are per source: a source this window never
      # touches keeps its stamp and fails `sync_freshness` at 72 h. The
      # registry is `sources list --json`; a blind window is not a green one.
      echo "gbrain-maintenance: sources list"
      sources=$(run_gbrain sources list --json | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    raise SystemExit(1)
for src in json.loads(raw[start:]).get("sources") or []:
    sid = src.get("id")
    if sid:
        print(sid)
') || sources=
      if [ -z "$sources" ]; then
        echo "gbrain-maintenance: sources list returned nothing - refusing a blind window" >&2
        exit 1
      fi

      for src in $sources; do
        echo "gbrain-maintenance: sync --source $src --no-pull"
        run_gbrain sync --source "$src" --no-pull || rc=1
      done

      echo "gbrain-maintenance: extract --stale"
      run_gbrain extract --stale || rc=1

      echo "gbrain-maintenance: dream --phase extract_atoms --drain --source $source_id"
      drain_rc=0
      run_gbrain dream --phase extract_atoms --drain --source "$source_id" --window 120 || drain_rc=$?
      if [ "$drain_rc" -eq 3 ]; then
        echo "gbrain-maintenance: extract_atoms backlog not empty in this window (rc=3) - next window continues" >&2
      elif [ "$drain_rc" -ne 0 ]; then
        echo "gbrain-maintenance: extract_atoms drain failed rc=$drain_rc" >&2
        rc=1
      fi
      # A named non-default source runs only the deterministic freshness
      # phases; default runs the full cycle that stamps last_full_cycle_at.
      for src in $sources; do
        echo "gbrain-maintenance: dream --source $src"
        run_gbrain dream --source "$src" || rc=1
      done

      exit "$rc"

    '';
  };
in
{
  config = lib.mkIf gbrainCfg.enable {
    systemd.services.gbrain-maintenance = {
      description = "GBrain maintenance window (sole-writer sync, link + atom extraction)";
      after = [
        "network-online.target"
        "gbrain-mcp-http.service"
      ];
      wants = [ "network-online.target" ];
      # The brain CLI and its data live under the agent state dir.
      unitConfig.RequiresMountsFor = userHome;
      # Same model/embedding plane the serve is started with (hermes-pnp
      # modules/gbrain-nixos.nix). The file plane in ~/.gbrain/config.json holds
      # the same values today; the env override must not drift from it, because
      # a sync that embeds under the wrong width fails against the live column.
      environment =
        lib.optionalAttrs (gbrainCfg.model != null) { GBRAIN_MODEL = gbrainCfg.model; }
        // lib.optionalAttrs (gbrainCfg.embeddingModel != null) {
          GBRAIN_EMBEDDING_MODEL = gbrainCfg.embeddingModel;
        }
        // lib.optionalAttrs (gbrainCfg.embeddingDimensions != null) {
          GBRAIN_EMBEDDING_DIMENSIONS = toString gbrainCfg.embeddingDimensions;
        };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${maintenance}/bin/gbrain-maintenance";
        # The CLI resolves its brain from $HOME and the configured working dir.
        WorkingDirectory = userHome;
        TimeoutStartSec = 3600;
        # The same secret plane the serve runs with (/run/hermes.env).
        EnvironmentFile = map (path: "-${toString path}") agent.environmentFiles;
        # The serve's 512M cap is free while it is down; the LLM-bearing drain
        # runs here and must not take the host with it.
        MemoryMax = "1536M";
        OOMScoreAdjust = 300;
        PrivateTmp = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

    systemd.timers.gbrain-maintenance = {
      description = "Daily GBrain maintenance window (sync + link/atom extraction)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # 04:15 local: after the Sunday 03:00 autoUpgrade (up to 30 min delay)
        # and its reboot, before the 05:30 hermes-agent reclaim and the 06:15
        # banking window. The brain MCP is down for the length of the window,
        # so it sits in the quiet hour only.
        OnCalendar = "*-*-* 04:15:00";
        # No catch-up: a window missed while the host was down must not take the
        # brain MCP offline mid-morning (same rule as hermes-agent-reclaim).
        Persistent = false;
        RandomizedDelaySec = "5m";
        Unit = "gbrain-maintenance.service";
      };
    };
  };
}
