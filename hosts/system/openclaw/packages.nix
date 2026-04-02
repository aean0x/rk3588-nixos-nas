{
  apt = [
    "git"
    "curl"
    "jq"
    "python3-pip"
    "python3-venv"
    "ffmpeg"
    "build-essential"
    "ca-certificates"
    "chromium"
  ];

  pip = [ ];

  npm = [
    "@steipete/bird"
    "playwright"
  ];

  pnpm = [
    "@clawdbot/lobster"
  ];

  uv = [ ];

  custom = [
    "uv"
    "uvx"
    "goplaces"
  ];
}
