# Host RAM/CPU caps, admin socket, sudo hermes CLI, hermes group.
# WebUI/browser jails use typed container.memory / cpus / shmSize.
# Official agent RAM still uses extraOptions — do not mkForce that list for RAM.
{
  config,
  lib,
  settings,
  ...
}:
{
  # Gateway + kanban fan-out. Raised 1g -> 2g (2026-09-20): at 1g the jail sat at
  # memory.max (peak 1075 MiB > 1073 MiB cap, memory.events max ~239k, swap
  # disabled), so the cgroup OOM killer took the largest task -- the gateway
  # (pid 1) -- and killed every in-flight kanban worker with it: 11 deaths in 9
  # days, 7 of them inside the 06:00-08:00 cron window. Not the host-global
  # killer and not systemd-oomd: host mem_available held 1.7-3.6 GiB and swap
  # 41-53% before each kill. Peak demand measured at the kills: gateway
  # ~600 MiB VmHWM + 2 dispatcher workers (~240 MiB each) + one cron agent
  # (~300 MiB) = ~1.4 GiB. memory-swap stays equal to memory: swapping the jail's
  # live heap trades OOM kills for stalls. Cron-side companion rule (one agent at
  # a time, 06:00-07:00): skill feng-scheduled-ops -> references/cron-job-catalog.md.
  services.hermes-agent.container.extraOptions = [
    "--memory=2g"
    "--memory-swap=2g"
    "--cpus=1"
    "--oom-score-adj=500"
  ];

  # WebUI: up to 3 agent threads. Raised 2560m -> 3g: the dashboard was
  # sitting at ~1.2-1.6g idle after the browser-lease work, and a 2.5g
  # ceiling still left it swapping SSE streams. Cap, not a blank cheque.
  services.hermesPnP.webui.container.memory = "3g";
  services.hermesPnP.webui.container.memorySwap = "3g";
  services.hermesPnP.webui.container.cpus = 2;
  services.hermesPnP.webui.container.oomScoreAdj = 500;

  # Browser: consumer maxTabs = 3. 1g holds. shm is /tmp
  # (--disable-dev-shm-usage); do not also set shmSize.
  services.hermesPnP.browser.container.memory = "1g";
  services.hermesPnP.browser.container.memorySwap = "1g";
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
