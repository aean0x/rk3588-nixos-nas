# Shared agent runtime — package + store-safe env for every Hermes entrypoint.
#
# Gateway (container) and WebUI (in-process host) must consume the *same*
# derivation and the *same* env map. Do not re-override extras in webui.
#
# Silence markers: _is_token still uses singular _canonical_silence_candidate
# so **[SILENT]** / *NO_REPLY* fail. Patch via hermesVenv + PYTHONPATH.
# Drop silence wrap when upstream _is_token uses _canonical_silence_candidates.
#
# Bundled plugins: upstream Nix keeps plugin.yaml under $out/share/hermes-agent
# and sets HERMES_BUNDLED_* only on the wrapped hermes binary. Container and
# WebUI never exec that wrapper, so this file injects the share map into
# process env for both.
{
  lib,
  pkgs,
  inputs,
  config,
  hermes,
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

  # `upstream` is hermes-agent `full` (kitchen-sink extras). Instantiating
  # with extraDependencyGroups=[] *replaces* that list and strips firecrawl-py
  # from passthru.hermesVenv. Bake the *service* extras here so cfg.package
  # IS the effective venv. Upstream's module may override again with the same
  # extras (identity). Do not default this to `full` — that realizes extras we
  # did not declare on the service.
  agentCfg = config.services.hermes-agent;
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
  ) {
    extraPythonPackages = agentCfg.extraPythonPackages;
    extraDependencyGroups = agentCfg.extraDependencyGroups;
  };

  # Same package-data env the upstream $out/bin/hermes makeWrapper sets
  # (share/ has plugin.yaml; site-packages does not), plus the silence
  # PYTHONPATH. Host-safe: store paths only. Container-only remaps (PATH,
  # /data/…, HERMES_PY) stay in toolbox.nix extraOptions.
  pkg = hermesAgentFixed;
  share = "${pkg}/share/hermes-agent";
  hermesRuntimeEnv = {
    HERMES_BUNDLED_PLUGINS = "${share}/plugins";
    HERMES_BUNDLED_SKILLS = "${share}/skills";
    HERMES_OPTIONAL_SKILLS = "${share}/optional-skills";
    HERMES_BUNDLED_LOCALES = "${share}/locales";
    HERMES_OPTIONAL_MCPS = "${share}/optional-mcps";
    HERMES_WEB_DIST = "${share}/web_dist";
    HERMES_TUI_DIR = "${pkg}/ui-tui";
    PYTHONPATH = "${silenceFixedGateway}/${siteRel}";
  };
in
{
  services.hermes-agent.package = lib.mkForce hermesAgentFixed;

  # WebUI and any other second agent process inherit this map as-is.
  _module.args.hermesRuntimeEnv = hermesRuntimeEnv;

  services.hermes-agent.environment = hermesRuntimeEnv;

  # Same map as environment{}, docker --env form (container does not exec the wrapper).
  services.hermes-agent.container.extraOptions = hermes.mkDockerEnv hermesRuntimeEnv;
}
