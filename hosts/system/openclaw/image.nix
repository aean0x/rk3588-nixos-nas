{ pkgs, ... }:
let
  baseImage = "ghcr.io/phioranex/openclaw-docker:latest";
  customImage = "openclaw-custom:latest";

  # ── Editable dependency lists ────────────────────────────────
  # prettier-ignore
  aptPackages = [
    "git"
    "curl"
    "jq"
    "nodejs"
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
  ];

  pnpmPackages = [
    "@clawdbot/lobster"
  ];

  uvPackages = [
    # "some-package"
  ];

  # ── Dockerfile fragments ────────────────────────────────────
  aptLine = builtins.concatStringsSep " " aptPackages;

  pipStep =
    if pipPackages == [ ] then
      ""
    else
      ''
        RUN pip install --no-cache-dir --break-system-packages ${builtins.concatStringsSep " " pipPackages}
      '';

  npmStep =
    if npmPackages == [ ] then
      ""
    else
      ''
        RUN npm install -g pnpm ${builtins.concatStringsSep " " npmPackages}
      '';

  pnpmStep =
    if pnpmPackages == [ ] then
      ""
    else
      ''
        RUN pnpm add -g ${builtins.concatStringsSep " " pnpmPackages}
      '';

  uvStep =
    if uvPackages == [ ] then
      ""
    else
      ''
        RUN uv pip install --system ${builtins.concatStringsSep " " uvPackages}
      '';

in
{
  # Build custom image on-device (native docker build, no qemu)
  systemd.services.openclaw-builder = {
    description = "Build custom OpenClaw image with Docker CLI";
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
      docker build -t ${customImage} - <<'EOF'
      FROM ${baseImage}
      USER root

      # System packages
      RUN rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* && \
          apt-get update && \
          apt-get install -y --no-install-recommends ${aptLine} && \
          rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

      # uv (Rust-based Python toolchain)
      RUN curl -LsSf https://github.com/astral-sh/uv/releases/download/0.5.0/uv-aarch64-unknown-linux-gnu.tar.gz | \
          tar -xzf - --strip-components=1 -C /usr/local/bin uv-aarch64-unknown-linux-gnu/uv uv-aarch64-unknown-linux-gnu/uvx && \
          chmod +x /usr/local/bin/uv /usr/local/bin/uvx

      # Docker CLI (for sandbox spawning)
      RUN curl -fsSL https://download.docker.com/linux/static/stable/aarch64/docker-26.1.3.tgz | \
          tar -xzf - --strip-components=1 -C /usr/local/bin docker/docker && \
          chmod +x /usr/local/bin/docker && \
          ln -sf /usr/local/bin/docker /usr/bin/docker

      # goplaces
      RUN curl -fsSL https://github.com/steipete/goplaces/releases/download/v0.3.0/goplaces_0.3.0_linux_arm64.tar.gz | \
          tar -xzf - goplaces && \
          mv goplaces /usr/local/bin/goplaces && \
          chmod +x /usr/local/bin/goplaces

      # Dependency install steps (pip / npm / pnpm / uv)
      ${pipStep}${npmStep}${pnpmStep}${uvStep}

      # Docker group + permissions
      RUN groupadd -g 131 docker 2>/dev/null || true && \
          usermod -aG docker node
      RUN chmod 755 /usr/local/bin/docker

      # Directory setup
      RUN mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial \
                   /home/node/.cache/uv /home/node/.local/share/uv \
                   /tmp /dev/shm && \
          chown -R 1000:1000 /home/node /tmp && \
          chmod -R 1777 /tmp /dev/shm && \
          chown -R _apt:root /var/lib/apt /var/cache/apt 2>/dev/null || true

      # OpenClaw CLI wrapper
      RUN printf '#!/bin/sh\nexec node /app/dist/index.js "$@"\n' > /usr/local/bin/openclaw && \
          chmod +x /usr/local/bin/openclaw
      RUN git config --global --add safe.directory '*'

      USER 1000:1000
      EOF

      # Extract tools into workspace so sandbox binds stay within allowed roots
      mkdir -p /home/node/.openclaw/workspace/.tools
      docker run --rm --entrypoint sh ${customImage} -c 'tar cf - /usr/local/bin/' | \
        tar xf - --strip-components=3 -C /home/node/.openclaw/workspace/.tools
      chown -R 1000:1000 /home/node/.openclaw/workspace/.tools
    '';
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "300";
    };
  };
}
