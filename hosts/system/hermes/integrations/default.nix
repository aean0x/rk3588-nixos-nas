# Hermes integrations: PnP plugins + MCP clients + host skills.
# Plugin *code* lives in flake input hermes-pnp. HMC is a host pin.
{
  lib,
  hermes,
  hmcPluginSrc,
  inputs,
  ...
}:
let
  skillsDir = ../skills;
  managedSkills = [
    "retrieval-reflex"
    "gbrain-http-auth"
  ];
in
{
  imports = [
    inputs.hermes-pnp.nixosModules.plugins
    ./mcp # composio via hermes-pnp mcp-proxy; gbrain HTTP client stays in ../gbrain.nix
    ./hmc.nix # composed HMC src → extraPlugins.hermes-context-manager
  ];

  services.hermesPnP.plugins = {
    enable = [
      "gbrain-retrieval-reflex"
      "gbrain-memory-flush"
      "tool-call-coherency"
      "projects-auto-commit"
      "model-router"
      "secret-handoff"
    ];
    extraPlugins.hermes-context-manager = hmcPluginSrc;
    stateDir = hermes.stateDir;
    user = "hermes";
    group = "hermes";
  };

  # Host skills + HMC state. Plugin trees are installed by hermes-pnp.
  system.activationScripts.hermes-integrations-skills = lib.stringAfter [
    "users"
    "groups"
    "hermes-agent-setup"
    "hermes-pnp-plugins"
  ] ''
    install -d -m 2770 -o hermes -g hermes ${hermes.hermesHome}/hmc_state

    ${lib.concatMapStrings (name: ''
      install -d -m 0755 -o hermes -g hermes ${hermes.skills.host}/${name}
      install -m 0644 -o hermes -g hermes ${skillsDir}/${name}/SKILL.md \
        ${hermes.skills.host}/${name}/SKILL.md
    '') managedSkills}
  '';
}
