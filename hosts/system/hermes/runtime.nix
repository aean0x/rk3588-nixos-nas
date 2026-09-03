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
  # Gateway: one messaging thread. Official docker min is 1g; 512m OOMs on tools.
  services.hermes-agent.container.extraOptions = [
    "--memory=1g"
    "--memory-swap=1g"
    "--cpus=1"
    "--oom-score-adj=500"
  ];

  # WebUI: up to 3 agent threads. Raised 2g -> 2.5g (2560m): the 2g ceiling
  # was hit at ~100% with ~1GB swapped, throttling the WebUI's SSE streams.
  services.hermesPnP.webui.container.memory = "2560m";
  services.hermesPnP.webui.container.memorySwap = "2560m";
  services.hermesPnP.webui.container.cpus = 2;
  services.hermesPnP.webui.container.oomScoreAdj = 500;

  # Browser: consumer maxTabs = 3. 1g holds. shm is /tmp
  # (--disable-dev-shm-usage); do not also set shmSize.
  services.hermesPnP.browser.container.memory = "1g";
  services.hermesPnP.browser.container.memorySwap = "1g";
  services.hermesPnP.browser.container.cpus = 2;
  services.hermesPnP.browser.container.oomScoreAdj = 500;

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
