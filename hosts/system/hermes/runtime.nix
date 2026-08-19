# Host RAM/CPU caps, sudo hermes CLI, hermes group.
# WebUI/browser are OCI jails — cap via extraOptions, not host MemoryMax.
# Browser shm default is 2g; force 256m so it fits the 1g cgroup.
{
  config,
  lib,
  settings,
  ...
}: let
  resources = {
    memoryDocker = "2g";
    browserMemoryDocker = "1g";
    cpus = 2;
    oomScoreAdjust = 500;
  };
  dockerCap = mem: [
    "--memory=${mem}"
    "--memory-swap=${mem}"
    "--cpus=${toString resources.cpus}"
    "--oom-score-adj=${toString resources.oomScoreAdjust}"
  ];
in {
  services.hermes-agent.container.extraOptions = dockerCap resources.memoryDocker;

  services.hermesPnP.webui.container.extraOptions = lib.mkAfter (dockerCap resources.memoryDocker);

  services.hermesPnP.browser.container.extraOptions = lib.mkForce (
    [
      "--shm-size=256m"
      "--init"
    ]
    ++ dockerCap resources.browserMemoryDocker
  );

  systemd.services.gbrain-mcp-http.serviceConfig = lib.mkIf config.services.hermesPnP.gbrain.enable {
    MemoryMax = "1G";
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
