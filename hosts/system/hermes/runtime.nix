# Host runtime policy: 8GiB RAM/CPU caps, sudo hermes CLI, group membership.
# Applies the options it owns — do not re-export numbers through _module.args.
#
# Compression / context window live in hermes.nix (official settings).
# Paths, toolbox PATH, browser CDP/gate, GBrain serve, WebUI pairing — hermes-pnp.
# WebUI + browser are OCI-jailed when hermesPnP.container.enable (this host).
# Host systemd MemoryMax does not apply to those containers — cap via extraOptions.
{
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

  services.hermesPnP.browser.container.extraOptions = lib.mkAfter (
    dockerCap resources.browserMemoryDocker
  );

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
