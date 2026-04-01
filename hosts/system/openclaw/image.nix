{ pkgs, ... }:
let
  gatewayBaseImage = "ghcr.io/phioranex/openclaw-docker:latest";
  gatewayImage = "openclaw-custom:latest";
  sandboxBaseImage = "node:22-bookworm-slim";
  sandboxImage = "openclaw-sandbox-custom:latest";

  # ── Editable dependency lists ────────────────────────────────
  # prettier-ignore
  aptPackages = [
    "git"
    "curl"
    "jq"
    "python3-pip"
    "python3-venv"
    "ffmpeg"
    "build-essential"
    "ca-certificates"
  ];

  pipPackages = [
    # "some-package"
  ];

  npmPackages = [
    "@steipete/bird"
    "playwright"
  ];

  pnpmPackages = [
    "@clawdbot/lobster"
  ];

  uvPackages = [
    # "some-package"
  ];

  npxCommands = [
    "playwright install --with-deps chromium"
  ];

  # ── Dockerfile fragments ────────────────────────────────────
  mkPkgStep =
    cmd: pkgList:
    if pkgList == [ ] then
      ""
    else
      ''
        RUN ${cmd} ${builtins.concatStringsSep " " pkgList}
      '';

  aptLine = builtins.concatStringsSep " " aptPackages;
  pipStep = mkPkgStep "pip install --no-cache-dir --break-system-packages" pipPackages;
  npmStep = mkPkgStep "npm install -g" npmPackages;
  uvStep = mkPkgStep "uv pip install --system" uvPackages;
  pnpmStep =
    if pnpmPackages == [ ] then
      ""
    else
      ''
        RUN PNPM_HOME=/usr/local/bin pnpm add -g ${builtins.concatStringsSep " " pnpmPackages}
      '';
  npxStep =
    if npxCommands == [ ] then
      ""
    else
      builtins.concatStringsSep "" (
        map (cmd: ''
          RUN npx ${cmd}
        '') npxCommands
      );

  # ── Shared Dockerfile steps (used by both gateway and sandbox) ──
  sharedSteps = ''
    USER root

    # System packages
    RUN rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* && \
        apt-get update && \
        apt-get install -y --no-install-recommends ${aptLine} && \
        rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

    # uv + uvx
    RUN curl -fsSL https://github.com/astral-sh/uv/releases/download/0.5.0/uv-aarch64-unknown-linux-gnu.tar.gz | \
        tar -xzf - --strip-components=1 -C /usr/local/bin \
          uv-aarch64-unknown-linux-gnu/uv uv-aarch64-unknown-linux-gnu/uvx
    RUN chmod +x /usr/local/bin/uv /usr/local/bin/uvx

    # Ensure pnpm is available (not in all base images)
    RUN npm install -g pnpm || true

    # Dependency install steps (pip / npm / pnpm / uv / npx)
    ${pipStep}${npmStep}${pnpmStep}${uvStep}${npxStep}

    # Common directory setup
    RUN mkdir -p /home/node/.cache/uv /home/node/.local/share/uv \
                 /tmp /dev/shm /var/tmp && \
        chown -R 1000:1000 /home/node /tmp /var/tmp && \
        chmod -R 1777 /tmp /dev/shm
    RUN git config --global --add safe.directory '*'
  '';

in
{
  systemd.services.openclaw-builder = {
    description = "Build custom OpenClaw gateway and sandbox images";
    before = [
      "docker-openclaw-gateway.service"
      "docker-openclaw-cli.service"
    ];
    requiredBy = [
      "docker-openclaw-gateway.service"
      "docker-openclaw-cli.service"
    ];
    path = [
      pkgs.docker
      pkgs.gnutar
      pkgs.coreutils
    ];
    script = ''
      # ── Gateway image ──────────────────────────────────────────
      docker build -t ${gatewayImage} - <<'GATEWAY_EOF'
      FROM ${gatewayBaseImage}
      ${sharedSteps}

      # Docker CLI (gateway-only)
      RUN curl -fsSL https://download.docker.com/linux/static/stable/aarch64/docker-26.1.3.tgz | \
          tar -xzf - --strip-components=1 -C /usr/local/bin docker/docker

      # goplaces (gateway-only)
      RUN curl -fsSL https://github.com/steipete/goplaces/releases/download/v0.3.0/goplaces_0.3.0_linux_arm64.tar.gz | \
          tar -xzf - -C /usr/local/bin goplaces

      RUN chmod +x /usr/local/bin/docker /usr/local/bin/goplaces

      # Docker group (gateway-only)
      RUN groupadd -g 131 docker 2>/dev/null || true && \
          usermod -aG docker node

      # Gateway-specific dirs
      RUN mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial \
                   /var/tmp/openclaw-compile-cache && \
          chown 1000:1000 /var/tmp/openclaw-compile-cache && \
          chown -R _apt:root /var/lib/apt /var/cache/apt 2>/dev/null || true

      # OpenClaw CLI wrapper (gateway-only)
      RUN printf '#!/bin/sh\nexec node /app/dist/index.js "$@"\n' > /usr/local/bin/openclaw && \
          chmod +x /usr/local/bin/openclaw

      USER 1000:1000
      GATEWAY_EOF

      # ── Sandbox image ──────────────────────────────────────────
      docker build -t ${sandboxImage} - <<'SANDBOX_EOF'
      FROM ${sandboxBaseImage}
      ${sharedSteps}

      USER 1000:1000
      SANDBOX_EOF
    '';
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "600";
    };
  };
}
