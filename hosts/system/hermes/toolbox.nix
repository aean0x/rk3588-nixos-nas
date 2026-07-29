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
      pkgs.netcat-gnu
      pkgs.socat
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

  # Keep PATH in .env for load_hermes_dotenv (container). Host CLI uses docker-exec
  # routing in container mode, so container paths in dotenv are acceptable when
  # the binary routes into the container before tool use.
  dotenvSanitize = pkgs.writeShellScript "hermes-toolbox-dotenv-sanitize" ''
    env_file=/var/lib/hermes/.hermes/.env
    if [ -f "$env_file" ]; then
      # Drop host-breaking / obsolete keys only.
      sed -i '/^MESSAGING_CWD=/d;/^TERMINAL_CWD=/d;/^AGENT_BROWSER_EXECUTABLE_PATH=/d' \
        "$env_file" 2>/dev/null || true
      # Ensure toolbox PATH is present (module rewrite can race activation order).
      if ! grep -q '^PATH=.*/data/toolbox/bin' "$env_file" 2>/dev/null; then
        sed -i '/^PATH=/d' "$env_file" 2>/dev/null || true
        echo 'PATH=${agentPath}' >> "$env_file"
      fi
      if ! grep -q '^HERMES_PY=' "$env_file" 2>/dev/null; then
        echo 'HERMES_PY=/data/toolbox/bin/python3' >> "$env_file"
        echo 'HERMES_PYTHON=/data/toolbox/bin/python3' >> "$env_file"
      fi
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
    # Written to $HERMES_HOME/.env by the module (load_hermes_dotenv).
    # Hermes wrapper may still rewrite PATH; docker --env below is the reliable
    # source for the gateway process + terminal children in container mode.
    environment = {
      PATH = agentPath;
      HERMES_PY = "/data/toolbox/bin/python3";
      HERMES_PYTHON = "/data/toolbox/bin/python3";
    };

    # Identity-hash-sensitive: recreates container when these change (expected once).
    container.extraOptions = [
      "--env"
      "PATH=${agentPath}"
      "--env"
      "HERMES_PY=/data/toolbox/bin/python3"
      "--env"
      "HERMES_PYTHON=/data/toolbox/bin/python3"
    ];

    # Host hermes user profile (extraPackages); also helps doctor/CLI on host.
    extraPackages = with pkgs; [
      git
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
      netcat-gnu
      socat
      python3
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
