# WebUI extension installs must land in a writable directory.
#
# hermes-pnp (modules/webui/default.nix) points HERMES_WEBUI_EXTENSION_DIR at
# the model-router plugin's webui dir inside the Nix store so the Model Router
# toolbar loads in the WebUI shell. hermes-webui uses that same env var as the
# gallery-install target, so every install attempt (external-app-tab,
# desktop-companion, mobile-conversations) tries to mkdir inside /nix/store and
# dies with EROFS/Errno 30 ("extension install failed" in errors.log).
#
# Redirect the extension dir to a writable directory under the WebUI state dir
# (same path inside the OCI jail, owned by the webui user) and mirror the
# plugin's bundled assets there so the Model Router UI keeps loading while
# gallery installs succeed.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkForce mkAfter;
  pnp = config.services.hermesPnP;
  webui = config.services.hermes-webui;
  # Read-only source: the model-router plugin's webui dir in the store. Null
  # when the plugin is disabled; in that case pnp does not wire an extension
  # dir and there is nothing to redirect.
  bundled = pnp.pluginInstall.webuiExtensionDir;
  # Writable extension root. Same path inside and outside the jail
  # (webui.stateDir is bind-mounted 1:1) and owned by the webui user, so
  # gallery installs can create extension subdirs and write the install
  # manifest next to the seeded bundled assets.
  extDir = "${webui.stateDir}/extensions";
in
mkIf (pnp.enable && pnp.webui.enable && bundled != null) {
  services.hermes-webui.extraEnvironment.HERMES_WEBUI_EXTENSION_DIR = mkForce extDir;

  # Guarantee the writable root exists with the right owner from boot, before
  # the container starts. Seeding (below) fills it with the bundled assets.
  systemd.tmpfiles.rules = [
    "d ${extDir} 0700 ${webui.user} ${webui.group} - -"
  ];

  # Seed on webui start, not via activationScripts (no Nix oneshots for
  # leftover/bootstrap copies). Plain copy, never --delete, so gallery
  # companion extensions in subdirectories survive.
  systemd.services.hermes-webui.preStart = mkAfter ''
    mkdir -p '${webui.stateDir}' '${extDir}'
    chown ${webui.user}:${webui.group} '${webui.stateDir}' '${extDir}'
    chmod 0700 '${webui.stateDir}' '${extDir}'
    ${pkgs.coreutils}/bin/cp -a '${bundled}'/. '${extDir}'/
    chown -R ${webui.user}:${webui.group} '${extDir}'
  '';
}
