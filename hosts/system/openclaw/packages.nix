{ lib, ... }:

{
  # All dependencies are typed + minimal. Order = Dockerfile execution order.
  dependencies = [
    # ── System packages (batched)
    {
      name = "apt-base";
      type = "apt";
      sandbox = true;
      packages = [
        "git"
        "curl"
        "jq"
        "python3-venv"
        "ffmpeg"
        "build-essential"
        "ca-certificates"
        "chromium"
      ];
    }

    # ── Tarballs (fully abstracted, no extractTo needed)
    {
      name = "uv";
      type = "tarball";
      sandbox = true;
      url = "https://github.com/astral-sh/uv/releases/download/0.5.0/uv-aarch64-unknown-linux-gnu.tar.gz";
      stripComponents = 1;
    }
    {
      name = "goplaces";
      type = "tarball";
      sandbox = true;
      url = "https://github.com/steipete/goplaces/releases/download/v0.3.0/goplaces_0.3.0_linux_arm64.tar.gz";
    }
    {
      name = "docker-cli";
      type = "tarball";
      sandbox = false;
      url = "https://download.docker.com/linux/static/stable/aarch64/docker-26.1.3.tgz";
      stripComponents = 1;
    }

    # ── npm / pnpm — package field optional (defaults to name)
    {
      name = "pnpm";
      type = "npm";
      sandbox = true;
    }
    {
      name = "node-tools";
      type = "node-workspace";
      sandbox = true;
      packages = {
        "playwright" = "latest";
        "@playwright/mcp" = "latest";
        "@clawdbot/lobster" = "latest";
        "@steipete/bird" = "latest";
        "mcporter" = "latest";
      };
      env = {
        PLAYWRIGHT_BROWSERS_PATH = "/ms-playwright";
      };
      post = "npx playwright install --with-deps chromium && chown -R 1000:1000 /ms-playwright";
    }

    # ── pip packages (batched, installed via uv)
    {
      name = "pip-base";
      type = "pip";
      sandbox = true;
      packages = [
        "openai-whisper"
      ];
    }
  ];
}
