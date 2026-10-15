# Host RAM/CPU caps, admin socket, sudo hermes CLI, hermes group, and the
# quiet-hour RSS reclaim for the agent gateway.
# WebUI/browser jails use typed container.memory / cpus / shmSize.
# Official agent RAM still uses extraOptions — do not mkForce that list for RAM.
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  # HERMES_HOME on the host; the jails see the same tree at /data.
  hermesHome = "${config.services.hermes-agent.stateDir}/.hermes";

  # Written by the gateway every loop tick, and read by the WebUI liveness
  # check — so the reclaim decision needs no docker call and no log parse.
  heartbeat = "${hermesHome}/state/gateway.heartbeat";

  # A fresh jail life baselines at 346-426 MiB and creeps ~123 MiB/day, so the
  # gate is crossed about every other day. Below it a restart buys nothing.
  thresholdKiB = 600 * 1024;

  # The heartbeat refreshes every few seconds; minutes of silence means the
  # gateway is not live, and a restart is then not a reclaim.
  maxAgeSeconds = 600;

  reclaim = pkgs.writeShellApplication {
    name = "hermes-agent-reclaim";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = ''
      # Restart the agent jail when — and only when — the gateway's own RSS says
      # the creep is worth the interruption. Driven by hermes-agent-reclaim.timer
      # in the 05:30 quiet hour. HERMES_AGENT_RECLAIM_DRY_RUN=1 reports the
      # decision without restarting (set by hand for a rehearsal; no unit sets it).
      heartbeat=${heartbeat}
      threshold_kib=${toString thresholdKiB}
      max_age_s=${toString maxAgeSeconds}

      log() {
        echo "hermes-agent-reclaim: $*"
      }

      if [ ! -r "$heartbeat" ]; then
        log "no readable heartbeat at $heartbeat - leaving the jail up"
        exit 0
      fi

      # A missing mtime reads as ancient, i.e. the same as a dead gateway.
      mtime=$(stat -c %Y "$heartbeat" || echo 0)
      age_s=$(( $(date +%s) - mtime ))
      if [ "$age_s" -gt "$max_age_s" ]; then
        log "heartbeat stale (''${age_s}s > ''${max_age_s}s), gateway not live - leaving the jail up"
        exit 0
      fi

      # {"pid": 1, ..., "mem": {"rss_kib": 824120, ...}}
      rss_kib=$(grep -o '"rss_kib":[[:space:]]*[0-9]\+' "$heartbeat" | head -n 1 | tr -cd '0-9' || true)
      if [ -z "$rss_kib" ]; then
        log "no rss_kib in $heartbeat - leaving the jail up"
        exit 0
      fi

      if [ "$rss_kib" -lt "$threshold_kib" ]; then
        log "gateway rss ''${rss_kib} kiB below the ''${threshold_kib} kiB gate - leaving the jail up"
        exit 0
      fi

      if [ "''${HERMES_AGENT_RECLAIM_DRY_RUN:-0}" = "1" ]; then
        log "gateway rss ''${rss_kib} kiB >= ''${threshold_kib} kiB - dry run, not restarting"
        exit 0
      fi

      log "gateway rss ''${rss_kib} kiB >= ''${threshold_kib} kiB - restarting hermes-agent.service"
      systemctl restart hermes-agent.service
      log "hermes-agent.service restarted"
    '';
  };
in
{
  # Gateway + kanban fan-out. Raised 1g -> 2g (2026-09-20): at 1g the jail sat at
  # memory.max (peak 1075 MiB > 1073 MiB cap, memory.events max ~239k, swap
  # disabled), so the cgroup OOM killer took the largest task -- the gateway
  # (pid 1) -- and killed every in-flight kanban worker with it: 11 deaths in 9
  # days, 7 of them inside the 06:00-08:00 cron window. Not the host-global
  # killer and not systemd-oomd: host mem_available held 1.7-3.6 GiB and swap
  # 41-53% before each kill. Peak demand measured at the kills: gateway
  # ~600 MiB VmHWM + 2 dispatcher workers (~240 MiB each) + one cron agent
  # (~300 MiB) = ~1.4 GiB.
  #
  # Swap: the live heap must not go to disk -- swapping it trades OOM kills for
  # stalls, which is what the 1g era did to the gateway. `--memory-swap` is the
  # memory+swap TOTAL, so "swap off" is --memory-swap == --memory, and on this
  # host that request inverts silently. Measured 2026-10-15: the jail's own leaf
  # reads memory.swap.max = max (UNLIMITED), 0.9-1.2 GB swapped, pgmajfault
  # 1.96M, memory.events `max` 647k, `oom_kill` 0 -- hours of thrash, no kill.
  # Both earlier links are clean: the generated pre-start carries --memory-swap
  # verbatim into `docker create` (read it back at
  # /nix/store/*-unit-script-hermes-agent-pre-start/bin/hermes-agent-pre-start)
  # and the daemon keeps the flag. The runtime drops it: on cgroup v2 the systemd
  # cgroup driver converts the v1 total to swap = memorySwap - memory = 0 and then
  # SKIPS a zero instead of writing it (opencontainers/cgroups v0.0.6
  # systemd/v2.go: `if swap != 0 { MemorySwapMax }`), so systemd's default stands:
  # unlimited. The cgroupfs driver writes the 0 correctly, so the bug is
  # driver-specific and invisible unless the leaf is read.
  #
  # Hence a small non-zero allowance: 2g + 32 MiB. The subtraction is non-zero,
  # the property is emitted, and the jail can page at most 32 MiB of cold memory
  # before the OOM killer is back in charge. The allowance is the DIFFERENCE
  # between the two numbers -- move --memory and move --memory-swap with it.
  #
  # Cron-side companion rule (one agent at a time, 06:00-07:00):
  # skill feng-scheduled-ops -> references/cron-job-catalog.md.
  services.hermes-agent.container.extraOptions = [
    "--memory=2g"
    "--memory-swap=2080m"
    "--cpus=1"
    "--oom-score-adj=500"
  ];

  # Reclaim the gateway RSS creep the cap above cannot: nothing inside the jail
  # gives it back — malloc_trim in the 60 s housekeeping pass frees 5-9 MiB per
  # pass against ~+123 MiB/day, and the pages cannot go anywhere else: the 32 MiB
  # swap allowance above is no home for a live heap. A container restart resets
  # pid 1 to its 346-426 MiB baseline, so one restart returns ~400-460 MiB to the
  # host.
  # Daily at 05:30, behind an RSS gate so a healthy / just-restarted jail is
  # left alone.
  #
  # Deliberately NOT a MemoryHigh on the jail: docker on cgroup v2 maps
  # --memory-reservation to memory.low (a protection, not a throttle) and has no
  # memory.high flag at all, so the only route would be a --cgroup-parent slice —
  # a second source of truth for one number, dependent on the daemon's cgroup
  # driver. With the jail's swap allowance this small it would not reclaim the
  # anon creep either; it would throttle allocations and stall the gateway
  # instead. Bound the jail with docker flags, never a unit property
  # (lib/oci-container.nix).
  systemd.services.hermes-agent-reclaim = {
    description = "Reclaim the agent gateway RSS creep (RSS-gated restart)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${reclaim}/bin/hermes-agent-reclaim";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      NoNewPrivileges = true;
      # systemctl talks to the system bus and nothing else.
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.hermes-agent-reclaim = {
    description = "Daily quiet-hour RSS reclaim for the agent gateway";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 05:30 local: after the Sunday 03:00 autoUpgrade and its reboot, 45 min
      # before the 06:15 office-scout cron window.
      OnCalendar = "*-*-* 05:30:00";
      # No catch-up: a window missed while the host was down must not restart
      # the jail mid-morning.
      Persistent = false;
    };
  };

  # WebUI: up to 3 agent threads. Raised 2560m -> 3g: the dashboard was
  # sitting at ~1.2-1.6g idle after the browser-lease work, and a 2.5g
  # ceiling still left it swapping SSE streams. Cap, not a blank cheque.
  services.hermesPnP.webui.container.memory = "3g";
  # 3g + 32 MiB, not 3g: same reason as the agent jail above -- an equal pair
  # computes to a zero swap request, which the runtime's systemd cgroup driver
  # drops, leaving the jail with unlimited swap instead of none.
  services.hermesPnP.webui.container.memorySwap = "3080m";
  services.hermesPnP.webui.container.cpus = 2;
  services.hermesPnP.webui.container.oomScoreAdj = 500;

  # Browser: consumer maxTabs = 3. 1g holds. shm is /tmp
  # (--disable-dev-shm-usage); do not also set shmSize.
  services.hermesPnP.browser.container.memory = "1g";
  # 1g + 32 MiB -- see the webui note above.
  services.hermesPnP.browser.container.memorySwap = "1040m";
  services.hermesPnP.browser.container.cpus = 2;
  services.hermesPnP.browser.container.oomScoreAdj = 500;

  # Per-renderer JS heap ceiling. Unset, a single runaway SPA grows one tab
  # until the cgroup kills the whole browser. 192m x 3 renderers (maxTabs) is
  # 576m, which leaves the browser process headroom inside the 1g cage.
  # extraArgs is list-typed, so this concatenates with the module's
  # --renderer-process-limit.
  services.hermesPnP.browser.extraArgs = [
    "--js-flags=--max-old-space-size=192"
  ];

  # Allowlisted restart from the jails. Not sudo, not docker.sock.
  services.hermesPnP.admin.enable = true;

  # PGLite + remote embeddings, not a local model.
  systemd.services.gbrain-mcp-http.serviceConfig = lib.mkIf config.services.hermesPnP.gbrain.enable {
    MemoryMax = "512M";
    OOMScoreAdjust = 400;
  };

  # hermes CLI runs as the hermes service user via sudo (reads .env).
  # Do not put hermes in the docker group — the socket is root-equivalent.
  users.users.${settings.adminUser}.extraGroups = [ "hermes" ];

  security.sudo.extraRules = [
    {
      users = [ settings.adminUser ];
      runAs = "hermes";
      commands = [
        {
          command = "/run/current-system/sw/bin/hermes";
          options = [
            "NOPASSWD"
            "SETENV"
          ];
        }
      ];
    }
  ];

  environment.shellAliases.hermes = "sudo -u hermes /run/current-system/sw/bin/hermes";
}
