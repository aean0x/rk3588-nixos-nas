# Everyday agent CLI toolkit for Hermes container mode.
# Pattern from Hetzner hermes-agent.nix: buildEnv → /var/lib/hermes/toolbox/bin
# appears in the container as /data/toolbox/bin (stateDir bind).
#
# Container PATH is runtime.nix containerProcessEnv → extraOptions --env
# (not persisted into .env — host CLI would otherwise inherit /data paths).
{
  lib,
  pkgs,
  hermes,
  ...
}:

let
  # withPackages already ships `python` and `python3`. Keep both names
  # explicit so a nixpkgs change cannot drop one.
  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      requests
      pyyaml
      toml
    ]
  );
  pythonBins = pkgs.runCommand "hermes-python" { } ''
    mkdir -p $out/bin
    ln -s ${pythonEnv}/bin/python3 $out/bin/python3
    ln -s ${pythonEnv}/bin/python3 $out/bin/python
  '';

  hermesToolbox = pkgs.buildEnv {
    name = "hermes-toolbox";
    paths = [
      pythonEnv
      pkgs.pandoc
      pkgs.bun
      pkgs.nodejs
      pkgs.git
      pkgs.ripgrep
      pkgs.jq
      pkgs.yq-go
      pkgs.curl
      pkgs.wget
      pkgs.unzip
      pkgs.zip
      pkgs.imagemagick
      pkgs.tree
      pkgs.rsync
      pkgs.openssh
      pkgs.ffmpeg
      pkgs.sox
      pkgs.poppler-utils
      pkgs.gnupg
      pkgs.age
      pkgs.file
      pkgs.which
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gnused
      pkgs.gnutar
      pkgs.gzip
      pkgs.bzip2
      pkgs.xz
      pkgs.zstd
      pkgs.p7zip
      pkgs.htop
      pkgs.ncdu
      pkgs.lsof
      pkgs.strace
      pkgs.tcpdump
      pkgs.nmap
      pkgs.netcat-gnu
      pkgs.socat
      # Chromium aliases for agent-browser / local tools (Hetzner parity).
      # Host sticky CDP is separate (browser.nix → BROWSER_CDP_URL); this is the
      # toolbox binary path agent-browser expects when not on remote CDP.
      (pkgs.runCommand "chromium-browser" { buildInputs = [ pkgs.chromium ]; } ''
        mkdir -p $out/bin
        ln -s ${pkgs.chromium}/bin/chromium $out/bin/chromium
        ln -s ${pkgs.chromium}/bin/chromium $out/bin/chrome
        ln -s ${pkgs.chromium}/bin/chromium $out/bin/google-chrome
      '')
    ];
  };

  # Hetzner model: never persist container-only PATH/HERMES_PY/AGENT_BROWSER into
  # .env. Host `hermes chat` (terminal.backend=local) loads dotenv and would
  # inherit /data/toolbox paths that do not exist on the host. Container gets
  # those via container.extraOptions --env from runtime.nix.
  dotenvSanitize = pkgs.writeShellScript "hermes-toolbox-dotenv-sanitize" ''
    env_file=${hermes.hermesHome}/.env
    if [ -f "$env_file" ]; then
      sed -i \
        '/^MESSAGING_CWD=/d;/^TERMINAL_CWD=/d;/^PATH=/d;/^HERMES_PY=/d;/^HERMES_PYTHON=/d;/^AGENT_BROWSER_EXECUTABLE_PATH=/d' \
        "$env_file" 2>/dev/null || true
      chown hermes:hermes "$env_file" 2>/dev/null || true
      chmod 640 "$env_file" 2>/dev/null || true
    fi
  '';

  containerProfile = pkgs.writeText "hermes-home-profile" ''
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    export PATH="${hermes.containerPath}"
  '';

  # WebUI (host) terminals snapshot PATH via `bash -l` + ~/.profile.
  # passwd HOME is ${hermes.stateDir}, not the container home below.
  # Without this, the snapshot is NixOS user defaults — no toolbox, no python3.
  hostProfile = pkgs.writeText "hermes-host-profile" ''
    if [ -d ${hermes.toolbox.host} ]; then
      export PATH="${hermes.hostPath}:$PATH"
    fi
  '';

  containerBashrc = pkgs.writeText "hermes-home-bashrc" ''
    [ -f "$HOME/.profile" ] && . "$HOME/.profile"
  '';
  # Host CLI wrapper (Hetzner hermes-cli-wrapper + forced container route).
  # Installed under /var/lib/hermes/bin — not named `hermes` in systemPackages.
  #
  # Upstream hermes routes via HERMES_HOME/.container-mode, but is_container()
  # false-positives on Docker *hosts* (mountinfo contains /var/lib/docker and
  # "containerd"), so get_container_exec_info() returns None and chat runs on
  # the host with container PATH (/data/toolbox missing). Force docker exec
  # when the marker is present (same fields as the NixOS activation marker).
  hermesCliWrapper = pkgs.writeShellScript "hermes-cli-wrapper" ''
    export PATH="${hermes.hostPath}:/nix/var/nix/profiles/default/bin:$PATH"
    export HOME="''${HOME:-${hermes.home}}"
    export HERMES_HOME="''${HERMES_HOME:-${hermes.hermesHome}}"

    if [ -z "''${HERMES_DEV:-}" ] && [ -f "''${HERMES_HOME}/.container-mode" ]; then
      backend=docker
      container_name=hermes-agent
      exec_user=hermes
      hermes_bin=/data/current-package/bin/hermes
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          \#*|"") continue ;;
          backend=*) backend="''${line#backend=}" ;;
          container_name=*) container_name="''${line#container_name=}" ;;
          exec_user=*) exec_user="''${line#exec_user=}" ;;
          hermes_bin=*) hermes_bin="''${line#hermes_bin=}" ;;
        esac
      done < "''${HERMES_HOME}/.container-mode"

      runtime="$(command -v "$backend" 2>/dev/null || true)"
      if [ -n "$runtime" ] && "$runtime" inspect "$container_name" >/dev/null 2>&1; then
        tty_flags=(-i)
        if [ -t 0 ] && [ -t 1 ]; then
          tty_flags=(-it)
        fi
        env_flags=()
        [ -n "''${TERM:-}" ] && env_flags+=(-e "TERM=$TERM")
        [ -n "''${COLORTERM:-}" ] && env_flags+=(-e "COLORTERM=$COLORTERM")
        [ -n "''${LANG:-}" ] && env_flags+=(-e "LANG=$LANG")
        [ -n "''${LC_ALL:-}" ] && env_flags+=(-e "LC_ALL=$LC_ALL")
        exec "$runtime" exec "''${tty_flags[@]}" -u "$exec_user" "''${env_flags[@]}" \
          "$container_name" "$hermes_bin" "$@"
      fi
    fi

    exec /run/current-system/sw/bin/hermes "$@"
  '';
in
{
  # Host login shells for `sudo -u hermes` / doctor.
  environment.etc."profile.d/hermes-agent-cli.sh" = {
    text = ''
      if [ -d ${hermes.toolbox.host} ]; then
        export PATH="${hermes.hostPath}:$PATH"
      fi
    '';
    mode = "0644";
  };

  # Login-shell snapshots (WebUI terminal uses bash -l) only reliably see
  # /run/current-system/sw/bin — not /var/lib/hermes/toolbox/bin.
  # pythonBins guarantees both `python` and `python3` on that path.
  environment.systemPackages = [ pythonBins ];

  services.hermes-agent = {
    # Do NOT put PATH / HERMES_PY / AGENT_BROWSER in `environment` — the module
    # merges that into $HERMES_HOME/.env, which host `hermes chat` loads and
    # which breaks host terminal (container /data/toolbox paths).
    environment = { };

    container.extraOptions = hermes.mkDockerEnv hermes.containerProcessEnv;
  };

  system.activationScripts.hermes-toolbox = lib.stringAfter [ "hermes-agent-setup" ] ''
    install -d -m 0755 -o hermes -g hermes ${hermes.stateDir}/toolbox
    ln -sfn ${hermesToolbox}/bin ${hermes.toolbox.host}

    install -d -m 0750 -o hermes -g hermes ${hermes.home}
    install -d -m 0750 -o hermes -g hermes ${hermes.home}/.npm-global
    install -d -m 0755 -o hermes -g hermes ${hermes.home}/.local/bin

    # Interactive / docker-exec shells inside the container.
    install -m 0644 -o hermes -g hermes ${containerProfile} ${hermes.home}/.profile
    install -m 0644 -o hermes -g hermes ${containerBashrc} ${hermes.home}/.bashrc
    # Host hermes user HOME (/var/lib/hermes) — WebUI bash -l snapshot.
    install -m 0644 -o hermes -g hermes ${hostProfile} ${hermes.stateDir}/.profile

    install -d -m 2770 -o hermes -g hermes ${hermes.skills.host}
    install -d -m 2770 -o hermes -g hermes ${hermes.plugins}

    install -d -m 0755 -o hermes -g hermes ${hermes.bin}
    install -m 0755 ${hermesCliWrapper} ${hermes.bin}/hermes-cli
    # MCP clients (composio via flake hermes-pnp): integrations/mcp/*.nix
  '';

  # Run after setup merges environmentFiles into .env so we can strip PATH again.
  system.activationScripts.hermes-toolbox-dotenv = lib.stringAfter [
    "hermes-agent-setup"
    "hermes-toolbox"
    "hermes-memory-manifest"
  ] ''
    ${dotenvSanitize}
  '';
}
