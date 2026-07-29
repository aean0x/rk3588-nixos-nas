# Fix hermes-agent 0.19.x packaging: split hermes_state_* modules missing from wheel.
#
# Upstream pyproject.toml [tool.setuptools] py-modules lists hermes_state but not:
#   hermes_state_common, hermes_state_portability, hermes_state_schema, hermes_state_search
# Those files exist in the repo root and hermes_state.py imports them. Without them:
#   - SessionDB fails → SQLite session store unavailable
#   - load_transcript() always [] / has_any_sessions() false
#   - Gateway re-stamps "user's very first message" intro every cold turn
#   - session_search / kanban state paths break
#
# Track: NousResearch/hermes-agent#74287 (and related packaging).
# Drop this overlay when upstream adds the four modules to py-modules.
{
  lib,
  pkgs,
  inputs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  upstream = inputs.hermes-agent.packages.${system}.default;

  # Source tree of the locked hermes-agent flake (repo root).
  hermesSrc = inputs.hermes-agent.outPath;

  # Python used by the sealed venv (3.12).
  siteRel = "lib/python3.12/site-packages";

  missingModules = [
    "hermes_state_common.py"
    "hermes_state_portability.py"
    "hermes_state_schema.py"
    "hermes_state_search.py"
  ];

  hermesStateModules = pkgs.runCommand "hermes-state-split-modules" { } ''
    mkdir -p "$out/${siteRel}"
    ${lib.concatMapStringsSep "\n" (name: ''
      if [ ! -f "${hermesSrc}/${name}" ]; then
        echo "missing ${name} in hermes-agent source ${hermesSrc}" >&2
        exit 1
      fi
      cp "${hermesSrc}/${name}" "$out/${siteRel}/${name}"
    '') missingModules}
  '';

  # The NixOS module may call package.override { extraPythonPackages; extraDependencyGroups }
  # when those are non-empty — preserve that API while re-applying our PYTHONPATH wrap.
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
      name = "hermes-agent-state-modules-fix";
      paths = [ base ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        for bin in hermes hermes-agent hermes-acp; do
          if [ -e "$out/bin/$bin" ]; then
            wrapProgram "$out/bin/$bin" \
              --prefix PYTHONPATH : "${hermesStateModules}/${siteRel}"
          fi
        done
      '';
      passthru = (base.passthru or { }) // {
        inherit hermesStateModules;
        unfixed = base;
      };
    }
  ) { };
in
{
  # Prefer our fixed package over the incomplete sealed wheel.
  services.hermes-agent.package = lib.mkForce hermesAgentFixed;

  # Belt-and-suspenders for children that inherit process env but not the wrapper.
  services.hermes-agent.environment.PYTHONPATH = "${hermesStateModules}/${siteRel}";

  # Container gateway: docker --env so hermes python children see modules.
  services.hermes-agent.container.extraOptions = [
    "--env"
    "PYTHONPATH=${hermesStateModules}/${siteRel}"
  ];
}
