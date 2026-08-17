# Hermes integrations: composer plugins + MCP clients + host skills.
# Plugin *code* lives in flake input hermes-pnp. HMC is a host pin.
{
  lib,
  hermes,
  hmcPluginSrc,
  ...
}: let
  skillsDir = ../skills;
  managedSkills = [
    "retrieval-reflex"
    "gbrain-http-auth"
  ];
in {
  imports = [
    ./mcp # composio via hermes-pnp mcp-proxy; gbrain HTTP client stays in ../gbrain.nix
    ./hmc.nix # composed HMC src → extraPlugins.hermes-context-manager
  ];

  services.hermesPnP.extraPlugins.hermes-context-manager = hmcPluginSrc;

  # Host skills + HMC state. Plugin trees are installed by hermes-pnp.
  system.activationScripts.hermes-integrations-skills =
    lib.stringAfter [
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
        '')
        managedSkills}
    '';
}
