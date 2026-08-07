# Hermes packaging patches.
#
# hermes_state_* split modules: present in 0.19.1 hermesVenv.
# Silence markers: _is_token still uses singular _canonical_silence_candidate
# so **[SILENT]** / *NO_REPLY* fail. Patch gateway via hermesVenv + PYTHONPATH.
#
# Outer package is a thin wrapper (bin/ + share/); Python lives in hermesVenv.
# Drop silence patch when upstream uses _canonical_silence_candidates in _is_token.
#
# Bundled plugins: upstream Nix intentionally keeps plugin.yaml trees under
# $out/share/hermes-agent/plugins and sets HERMES_BUNDLED_PLUGINS on the *wrapped*
# hermes binary. The container module runs hermes-agent-env/bin/hermes (venv
# entrypoint) without that wrapper, so discovery falls back to site-packages
# plugins/ (code only, no manifests) → empty web/image_gen registries.
# Inject the share path into the service + container env for both runtimes.
{
  lib,
  pkgs,
  inputs,
  config,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  upstream = inputs.hermes-agent.packages.${system}.default;
  hermesVenv = upstream.hermesVenv;

  siteRel = "lib/python3.12/site-packages";

  silenceFixedGateway = pkgs.runCommand "hermes-gateway-silence-fix" { } ''
    mkdir -p "$out/${siteRel}/gateway"
    ${pkgs.rsync}/bin/rsync -a --copy-links --chmod=Du+w,Fu+w \
      "${hermesVenv}/${siteRel}/gateway/" "$out/${siteRel}/gateway/"
    if grep -q 'return _canonical_silence_candidate(line) in LIVE_GATEWAY_SILENT_MARKERS' \
        "$out/${siteRel}/gateway/response_filters.py"; then
      ${pkgs.gnused}/bin/sed \
        's/return _canonical_silence_candidate(line) in LIVE_GATEWAY_SILENT_MARKERS/return any(c in LIVE_GATEWAY_SILENT_MARKERS for c in _canonical_silence_candidates(line))/' \
        "$out/${siteRel}/gateway/response_filters.py" > "$out/${siteRel}/gateway/response_filters.py.new"
      mv "$out/${siteRel}/gateway/response_filters.py.new" \
        "$out/${siteRel}/gateway/response_filters.py"
    fi
    if ! grep -q '_canonical_silence_candidates(line)' \
        "$out/${siteRel}/gateway/response_filters.py"; then
      echo "silence fix: expected _canonical_silence_candidates usage missing" >&2
      exit 1
    fi
  '';

  hermesAgentFixed = lib.makeOverridable (
    {
      extraPythonPackages ? [ ],
      extraDependencyGroups ? [ ],
    }:
    let
      base = upstream.override {
        inherit extraPythonPackages extraDependencyGroups;
      };
    in
    pkgs.symlinkJoin {
      name = "hermes-agent-silence-fix";
      paths = [ base ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        for bin in hermes hermes-agent hermes-acp; do
          if [ -e "$out/bin/$bin" ]; then
            wrapProgram "$out/bin/$bin" \
              --prefix PYTHONPATH : "${silenceFixedGateway}/${siteRel}"
          fi
        done
      '';
      passthru = (base.passthru or { }) // {
        inherit silenceFixedGateway;
        hermesVenv = base.hermesVenv or hermesVenv;
        unfixed = base;
      };
    }
  ) { };

  # Same package-data env the upstream $out/bin/hermes makeWrapper sets
  # (share/ has plugin.yaml; site-packages does not). Single map for agent
  # service + container + WebUI (see hermes-webui.nix).
  pkg = hermesAgentFixed;
  share = "${pkg}/share/hermes-agent";
  hermesPackageDataEnv = {
    HERMES_BUNDLED_PLUGINS = "${share}/plugins";
    HERMES_BUNDLED_SKILLS = "${share}/skills";
    HERMES_OPTIONAL_SKILLS = "${share}/optional-skills";
    HERMES_BUNDLED_LOCALES = "${share}/locales";
    HERMES_OPTIONAL_MCPS = "${share}/optional-mcps";
    HERMES_WEB_DIST = "${share}/web_dist";
    HERMES_TUI_DIR = "${pkg}/ui-tui";
  };
in
{
  services.hermes-agent.package = lib.mkForce hermesAgentFixed;

  # Expose for hermes-webui.nix (and any other second agent process).
  _module.args.hermesPackageDataEnv = hermesPackageDataEnv;

  services.hermes-agent.environment = hermesPackageDataEnv // {
    PYTHONPATH = "${silenceFixedGateway}/${siteRel}";
  };

  services.hermes-agent.container.extraOptions = lib.flatten (
    [
      [
        "--env"
        "PYTHONPATH=${silenceFixedGateway}/${siteRel}"
      ]
    ]
    ++ lib.mapAttrsToList (k: v: [
      "--env"
      "${k}=${v}"
    ]) hermesPackageDataEnv
  );
}
