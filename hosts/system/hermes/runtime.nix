# Shared Hermes runtime — single source of truth for paths, PATH maps, and
# agent resource caps. Gateway (docker) and WebUI (host systemd, in-process
# agent) consume the same numbers and strings. Not a workaround.
#
# Env injection rule:
#   environment / environmentFiles → host-safe, lands in $HERMES_HOME/.env
#   container.extraOptions --env    → generated from the same maps (do not retype)
#   WebUI extraEnvironment         → hermesRuntimeEnv + host remaps + UI-only
{ lib, ... }:
let
  stateDir = "/var/lib/hermes";
  home = "${stateDir}/home";
  hermesHome = "${stateDir}/.hermes";
  workspace = "${stateDir}/workspace";
  data = "/data";
  containerHome = "/home/hermes";

  sysPathTail = [
    "/run/current-system/sw/bin"
    "/usr/local/sbin"
    "/usr/local/bin"
    "/usr/sbin"
    "/usr/bin"
    "/sbin"
    "/bin"
  ];

  toolbox = {
    host = "${stateDir}/toolbox/bin";
    container = "${data}/toolbox/bin";
  };

  skills = {
    host = "${stateDir}/skills";
    container = "${data}/skills";
  };

  memoryRegistry = {
    host = "${stateDir}/memory/registry.json";
    container = "${data}/memory/registry.json";
  };

  gbrainAudit = {
    host = "${home}/.gbrain/audit";
    container = "${containerHome}/.gbrain/audit";
  };

  # Container gateway / MCP / terminal children.
  # Order: npm-global, bun globals (gbrain), toolbox, then system.
  containerPath = lib.concatStringsSep ":" (
    [
      "${containerHome}/.npm-global/bin"
      "${containerHome}/.bun/bin"
      toolbox.container
    ]
    ++ sysPathTail
  );

  # Host login / sudo -u hermes / WebUI. Toolbox first so bun is pkgs.bun.
  hostPath = lib.concatStringsSep ":" [
    toolbox.host
    "${home}/.bun/bin"
    "${home}/.npm-global/bin"
    "${home}/.local/bin"
    "/etc/profiles/per-user/hermes/bin"
    "/run/current-system/sw/bin"
    "/usr/bin"
    "/bin"
  ];

  # Display + compressor window. WebUI / gateway honor model.context_length.
  # Native compression fires at threshold × this; HMC uses the same ceiling.
  contextLimit = 200000;
  compressionThreshold = 0.30;
  compressionThresholdTokens = 60000; # contextLimit * 0.30

  # Both agent entrypoints (gateway container + WebUI process).
  resources = {
    memory = "2G";
    memoryDocker = "2g";
    cpus = 2;
    oomScoreAdjust = 500;
  };

  containerResourceOptions = [
    "--memory=${resources.memoryDocker}"
    "--memory-swap=${resources.memoryDocker}"
    "--cpus=${toString resources.cpus}"
    "--oom-score-adj=${toString resources.oomScoreAdjust}"
  ];

  systemdResourceConfig = {
    MemoryMax = resources.memory;
    CPUQuota = "${toString (resources.cpus * 100)}%";
    OOMScoreAdjust = resources.oomScoreAdjust;
  };

  # Must not persist into .env (host hermes chat would inherit /data paths).
  containerProcessEnv = {
    PATH = containerPath;
    HERMES_PY = "${toolbox.container}/python3";
    HERMES_PYTHON = "${toolbox.container}/python3";
    AGENT_BROWSER_EXECUTABLE_PATH = "${toolbox.container}/chromium";
  };

  mkDockerEnv = attrs: lib.flatten (lib.mapAttrsToList (k: v: [
    "--env"
    "${k}=${v}"
  ]) attrs);

  hermes = {
    inherit
      stateDir
      home
      hermesHome
      workspace
      data
      containerHome
      toolbox
      skills
      memoryRegistry
      gbrainAudit
      containerPath
      hostPath
      contextLimit
      compressionThreshold
      compressionThresholdTokens
      resources
      containerResourceOptions
      systemdResourceConfig
      containerProcessEnv
      mkDockerEnv
      ;
    bin = "${stateDir}/bin";
    plugins = "${stateDir}/plugins";
  };
in
{
  _module.args.hermes = hermes;
}
