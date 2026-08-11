# Everyday agent CLI toolkit for Hermes container mode.
# Pattern from Hetzner hermes-agent.nix: buildEnv → /var/lib/hermes/toolbox/bin
# appears in the container as /data/toolbox/bin (stateDir bind).
#
# PATH for the gateway is set via services.hermes-agent.environment (not persisted
# into .env — host CLI would otherwise inherit container-only paths).
{
  lib,
  pkgs,
  ...
}:

let
  hermesToolbox = pkgs.buildEnv {
    name = "hermes-toolbox";
    paths = [
      (pkgs.python3.withPackages (
        ps: with ps; [
          requests
          pyyaml
          toml
        ]
      ))
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

  # Container gateway / MCP / terminal children — match Hetzner hermes-agent.nix.
  # Order matters: bun globals (gbrain) then toolbox (Nix bun works on host+container).
  # Do not put ~/.local/bin first; agent dual-wrappers there break the Hetzner model.
  agentPath = lib.concatStringsSep ":" [
    "/home/hermes/.npm-global/bin"
    "/home/hermes/.bun/bin" # gbrain from `bun install -g` (container)
    "/data/toolbox/bin" # Nix bun + everyday tools (host-safe via /nix/store mount)
    "/run/current-system/sw/bin"
    "/usr/local/sbin"
    "/usr/local/bin"
    "/usr/sbin"
    "/usr/bin"
    "/sbin"
    "/bin"
  ];

  # Host login / sudo -u hermes: toolbox FIRST so `bun` is pkgs.bun (not curl stub-ld).
  hermesHostCliPath = "/var/lib/hermes/toolbox/bin:/var/lib/hermes/home/.bun/bin:/var/lib/hermes/home/.npm-global/bin:/var/lib/hermes/home/.local/bin:/etc/profiles/per-user/hermes/bin";

  # Hetzner model: never persist container-only PATH/HERMES_PY/AGENT_BROWSER into
  # .env. Host `hermes chat` (terminal.backend=local) loads dotenv and would
  # inherit /data/toolbox paths that do not exist on the host. Container gets
  # those via services.hermes-agent.environment + container.extraOptions --env.
  dotenvSanitize = pkgs.writeShellScript "hermes-toolbox-dotenv-sanitize" ''
    env_file=/var/lib/hermes/.hermes/.env
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
    # Same order as Hetzner: npm-global, bun globals, toolbox.
    export PATH="$HOME/.npm-global/bin:$HOME/.bun/bin:/data/toolbox/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
    export PATH="${hermesHostCliPath}:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
    export HOME="''${HOME:-/var/lib/hermes/home}"
    export HERMES_HOME="''${HERMES_HOME:-/var/lib/hermes/.hermes}"

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
      if [ -d /var/lib/hermes/toolbox/bin ]; then
        export PATH="${hermesHostCliPath}:$PATH"
      fi
    '';
    mode = "0644";
  };

  services.hermes-agent = {
    # Do NOT put PATH / HERMES_PY / AGENT_BROWSER in `environment` — the module
    # merges that into $HERMES_HOME/.env, which host `hermes chat` loads and
    # which breaks host terminal (container /data/toolbox paths). Hetzner keeps
    # these out of dotenv; container gets them only via docker --env below.
    environment = { };

    # Identity-hash-sensitive: recreates container when these change (expected once).
    container.extraOptions = [
      "--env"
      "PATH=${agentPath}"
      "--env"
      "HERMES_PY=/data/toolbox/bin/python3"
      "--env"
      "HERMES_PYTHON=/data/toolbox/bin/python3"
      "--env"
      "AGENT_BROWSER_EXECUTABLE_PATH=/data/toolbox/bin/chromium"
    ];

    # Host hermes user profile (extraPackages); also helps doctor/CLI on host.
    extraPackages = with pkgs; [
      git
      gh
      nodejs
      bun
      ripgrep
      jq
      yq-go
      curl
      wget
      unzip
      zip
      imagemagick
      tree
      rsync
      openssh
      ffmpeg
      sox
      poppler-utils
      gnupg
      age
      file
      which
      pandoc
      htop
      ncdu
      lsof
      strace
      tcpdump
      nmap
      netcat-gnu
      socat
      python3
      chromium
    ];
  };

  system.activationScripts.hermes-toolbox = lib.stringAfter [ "hermes-agent-setup" ] ''
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/toolbox
    ln -sfn ${hermesToolbox}/bin /var/lib/hermes/toolbox/bin

    install -d -m 0750 -o hermes -g hermes /var/lib/hermes/home
    install -d -m 0750 -o hermes -g hermes /var/lib/hermes/home/.npm-global
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.local/bin

    # Interactive / docker-exec shells inside the container.
    install -m 0644 -o hermes -g hermes ${containerProfile} /var/lib/hermes/home/.profile
    install -m 0644 -o hermes -g hermes ${containerBashrc} /var/lib/hermes/home/.bashrc

    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/skills
    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/plugins

    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/bin
    install -m 0755 ${hermesCliWrapper} /var/lib/hermes/bin/hermes-cli
    # MCP wrappers (maton, …): integrations/mcp/*.nix
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
