# Host runtime policy: 8GiB RAM/CPU caps, sudo hermes CLI, group membership.
# Applies the options it owns — do not re-export numbers through _module.args.
#
# Compression / context window live in hermes.nix (official settings).
# Paths, toolbox PATH, browser CDP, GBrain serve, WebUI pairing — hermes-pnp.
{
  settings,
  ...
}: let
  resources = {
    memory = "2G";
    memoryDocker = "2g";
    cpus = 2;
    oomScoreAdjust = 500;
  };
in {
  services.hermes-agent.container.extraOptions = [
    "--memory=${resources.memoryDocker}"
    "--memory-swap=${resources.memoryDocker}"
    "--cpus=${toString resources.cpus}"
    "--oom-score-adj=${toString resources.oomScoreAdjust}"
  ];

  systemd.services.hermes-webui.serviceConfig = {
    MemoryMax = resources.memory;
    CPUQuota = "${toString (resources.cpus * 100)}%";
    OOMScoreAdjust = resources.oomScoreAdjust;
  };

  # hermes CLI runs as the hermes service user via sudo (reads .env).
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
