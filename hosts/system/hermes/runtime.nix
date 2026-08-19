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

  # WebUI: up to 3 agent threads. 2g is the ceiling on this board.
  services.hermesPnP.webui.container.memory = "2g";
  services.hermesPnP.webui.container.memorySwap = "2g";
  services.hermesPnP.webui.container.cpus = 2;
  services.hermesPnP.webui.container.oomScoreAdj = 500;

  # Browser: 2-tab policy (maxTabs default). 1g holds with shm 256m.
  services.hermesPnP.browser.container.memory = "1g";
  services.hermesPnP.browser.container.memorySwap = "1g";
  services.hermesPnP.browser.container.cpus = 2;
  services.hermesPnP.browser.container.oomScoreAdj = 500;
  services.hermesPnP.browser.container.shmSize = "256m";

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
