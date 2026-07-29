# Hermes local browser — persistent Chromium + CDP + phone-reachable noVNC.
#
# Primary automation path: local sticky profile on home WAN (Starlink/residential).
# Browserless stays available for disposable scraping; it is NOT the checkout primary
# when this host already egresses a household IP.
#
# Surfaces:
# - CDP  http://127.0.0.1:9222          (loopback only — agent attach)
# - noVNC http://<host>:6080/vnc.html   (LAN/Tailscale — human captcha/fallback)
# - VNC   <host>:5900                   (optional raw; password-gated)
#
# Hybrid (phone):
# 1. Agent hits CF/AXS challenge over CDP
# 2. Agent sends noVNC URL + password on Telegram
# 3. You open it on the phone, tap the challenge in the SAME session
# 4. Reply "done" — agent continues with the same cookies
{
  lib,
  pkgs,
  settings,
  ...
}:
let
  profileDir = "/var/lib/hermes/browser-profile";
  logDir = "/var/lib/hermes/browser-logs";
  cdpPort = 9222;
  vncPort = 5900;
  novncPort = 6080;
  displayNum = "99";
  display = ":${displayNum}";
  cdpAddr = "127.0.0.1";

  # Password file for x11vnc (auto-created if missing).
  vncPassFile = "/var/lib/hermes/browser-vnc.pass";
  # Plain password + URLs for Hermes to relay (mode 0640 hermes).
  vncEnvFile = "/run/hermes-browser-vnc.env";
  cdpEnvFile = "/run/hermes-browser.env";
in
{
  environment.systemPackages = [
    pkgs.chromium
    pkgs.xvfb
    pkgs.x11vnc
    pkgs.novnc
    pkgs.python3Packages.websockify
    (pkgs.writeShellScriptBin "hermes-browser-status" ''
      set -euo pipefail
      echo "profile:  ${profileDir}"
      echo "cdp:      http://${cdpAddr}:${toString cdpPort}"
      echo "novnc:    http://0.0.0.0:${toString novncPort}/vnc.html"
      if ${pkgs.curl}/bin/curl -fsS --max-time 2 "http://${cdpAddr}:${toString cdpPort}/json/version"; then
        echo
        echo "cdp:      up"
      else
        echo "cdp:      down"
      fi
      if ${pkgs.curl}/bin/curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:${toString novncPort}/vnc.html"; then
        echo "novnc:    up"
      else
        echo "novnc:    down"
      fi
      if [[ -f ${vncEnvFile} ]]; then
        echo "--- relay env (password redacted) ---"
        ${pkgs.gnused}/bin/sed -E 's/(PASSWORD|VNC_PASSWORD)=.*/\1=***/' ${vncEnvFile}
      fi
      ${pkgs.systemd}/bin/systemctl is-active hermes-browser.service hermes-browser-vnc.service hermes-browser-novnc.service || true
    '')
  ];

  # Phone / LAN access to noVNC (password still required). Prefer Tailscale on cellular.
  networking.firewall.allowedTCPPorts = [
    novncPort
    # raw VNC optional; noVNC is the phone path. Keep closed unless needed:
    # vncPort
  ];

  systemd.tmpfiles.rules = [
    "d ${profileDir} 0750 hermes hermes - -"
    "d ${logDir} 0750 hermes hermes - -"
    "d /var/lib/hermes/home 0755 hermes hermes - -"
    "f ${cdpEnvFile} 0640 hermes hermes - "
    "f ${vncEnvFile} 0640 hermes hermes - "
  ];

  # Hermes browser_tool precedence (browser_tool.py):
  #   1. BROWSER_CDP_URL env  2. browser.cdp_url in config.yaml
  # BU_CDP_URL / HERMES_BROWSER_* are informal aliases only — not read by Hermes.
  services.hermes-agent = {
    environment = {
      BROWSER_CDP_URL = "http://${cdpAddr}:${toString cdpPort}";
      # aliases kept for agent skills / harness that still look for these names
      BU_CDP_URL = "http://${cdpAddr}:${toString cdpPort}";
      HERMES_BROWSER_CDP_URL = "http://${cdpAddr}:${toString cdpPort}";
      HERMES_BROWSER_PROFILE = profileDir;
      HERMES_BROWSER_NOVNC_PORT = toString novncPort;
    };
    settings.browser = {
      cdp_url = "http://${cdpAddr}:${toString cdpPort}";
      # attach to host Chromium on loopback
      allow_private_urls = true;
    };
  };

  # CDP + path env for Hermes container (host network → loopback works).
  systemd.services.hermes-browser-env = {
    description = "Write Hermes browser CDP/noVNC env";
    wantedBy = [ "multi-user.target" ];
    before = [ "hermes-agent.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      umask 027

      # Stable VNC password (create once).
      if [[ ! -s ${vncPassFile} ]]; then
        # 12 chars alnum — phone-typable
        pw="$(${pkgs.openssl}/bin/openssl rand -base64 18 | ${pkgs.coreutils}/bin/tr -dc 'A-Za-z0-9' | ${pkgs.coreutils}/bin/head -c 12)"
        echo -n "$pw" > ${vncPassFile}
        chown hermes:hermes ${vncPassFile}
        chmod 0600 ${vncPassFile}
        # x11vnc store
        ${pkgs.x11vnc}/bin/x11vnc -storepasswd "$pw" ${profileDir}/.vncpass
        chown hermes:hermes ${profileDir}/.vncpass
        chmod 0600 ${profileDir}/.vncpass
      fi
      pw="$(${pkgs.coreutils}/bin/cat ${vncPassFile})"

      host_ip="$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $7; exit}' || true)"
      if [[ -z "''${host_ip:-}" ]]; then
        host_ip="${settings.hostName}"
      fi

      cat > ${cdpEnvFile} <<EOF
# Auto-generated by hermes-browser.nix — do not edit
BROWSER_CDP_URL=http://${cdpAddr}:${toString cdpPort}
BU_CDP_URL=http://${cdpAddr}:${toString cdpPort}
HERMES_BROWSER_CDP_URL=http://${cdpAddr}:${toString cdpPort}
HERMES_BROWSER_PROFILE=${profileDir}
HERMES_BROWSER_NOVNC_URL=http://''${host_ip}:${toString novncPort}/vnc.html
HERMES_BROWSER_NOVNC_PORT=${toString novncPort}
EOF
      chown hermes:hermes ${cdpEnvFile}
      chmod 0640 ${cdpEnvFile}

      cat > ${vncEnvFile} <<EOF
# Auto-generated — agent may relay to user on captcha handoff
HERMES_BROWSER_NOVNC_URL=http://''${host_ip}:${toString novncPort}/vnc.html
HERMES_BROWSER_NOVNC_PASSWORD=$pw
HERMES_BROWSER_VNC_PASSWORD=$pw
EOF
      chown hermes:hermes ${vncEnvFile}
      chmod 0640 ${vncEnvFile}

      # Upsert into Hermes dotenv (activation may merge empty env files first).
      hermes_env=/var/lib/hermes/.hermes/.env
      if [[ -f "$hermes_env" ]]; then
        for key in BROWSER_CDP_URL BU_CDP_URL HERMES_BROWSER_CDP_URL HERMES_BROWSER_PROFILE HERMES_BROWSER_NOVNC_URL HERMES_BROWSER_NOVNC_PORT; do
          val="$(${pkgs.gnugrep}/bin/grep -E "^''${key}=" ${cdpEnvFile} | ${pkgs.coreutils}/bin/head -1 || true)"
          if [[ -n "$val" ]]; then
            ${pkgs.gnused}/bin/sed -i "/^''${key}=/d" "$hermes_env" 2>/dev/null || true
            echo "$val" >> "$hermes_env"
          fi
        done
        chown hermes:hermes "$hermes_env"
        chmod 0640 "$hermes_env"
      fi
    '';
  };

  systemd.services.hermes-agent = {
    after = [
      "hermes-browser-env.service"
      "hermes-browser.service"
    ];
    wants = [ "hermes-browser-env.service" ];
  };

  # Chromium on Xvfb (the automation surface).
  systemd.services.hermes-browser = {
    description = "Hermes persistent Chromium on Xvfb (CDP loopback)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "hermes-browser-env.service"
    ];
    wants = [
      "network-online.target"
      "hermes-browser-env.service"
    ];

    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      Restart = "on-failure";
      RestartSec = 5;
      MemoryMax = "2G";
      TimeoutStartSec = 60;
      StandardOutput = "append:${logDir}/chromium.stdout";
      StandardError = "append:${logDir}/chromium.stderr";
    };

    environment = {
      HOME = "/var/lib/hermes/home";
      XDG_CONFIG_HOME = "/var/lib/hermes/home/.config";
      XDG_CACHE_HOME = "/var/lib/hermes/home/.cache";
      DISPLAY = display;
    };

    script = ''
      set -euo pipefail
      mkdir -p ${profileDir} /var/lib/hermes/home ${logDir}

      rm -f /tmp/.X${displayNum}-lock /tmp/.X11-unix/X${displayNum} || true

      ${pkgs.xvfb}/bin/Xvfb ${display} -screen 0 1400x900x24 -ac +extension GLX +render -noreset &
      xvfb_pid=$!
      trap 'kill $xvfb_pid 2>/dev/null || true' EXIT
      sleep 1

      # --no-sandbox: hermes is an unprivileged service user without chrome-sandbox SUID.
      exec ${pkgs.chromium}/bin/chromium \
        --user-data-dir=${profileDir} \
        --remote-debugging-address=${cdpAddr} \
        --remote-debugging-port=${toString cdpPort} \
        --no-first-run \
        --no-default-browser-check \
        --no-sandbox \
        --disable-setuid-sandbox \
        --disable-dev-shm-usage \
        --disable-gpu \
        --window-size=1400,900 \
        --disable-features=TranslateUI \
        about:blank
    '';
  };

  # x11vnc mirrors Xvfb so a human can click captchas on the same session.
  systemd.services.hermes-browser-vnc = {
    description = "Hermes browser x11vnc (password-gated)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "hermes-browser.service"
      "hermes-browser-env.service"
    ];
    requires = [ "hermes-browser.service" ];

    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      Restart = "on-failure";
      RestartSec = 3;
      StandardOutput = "append:${logDir}/x11vnc.stdout";
      StandardError = "append:${logDir}/x11vnc.stderr";
    };

    environment.DISPLAY = display;

    # -localhost no: phone via Tailscale/LAN must reach it; password required.
    # CDP stays loopback-only; only the framebuffer is shared.
    script = ''
      set -euo pipefail
      # Wait for Xvfb
      for i in $(seq 1 30); do
        if [[ -e /tmp/.X11-unix/X${displayNum} ]]; then break; fi
        sleep 0.5
      done
      exec ${pkgs.x11vnc}/bin/x11vnc \
        -display ${display} \
        -rfbport ${toString vncPort} \
        -rfbauth ${profileDir}/.vncpass \
        -shared \
        -forever \
        -noxdamage \
        -wait 10 \
        -defer 10 \
        -o ${logDir}/x11vnc.log
    '';
  };

  # noVNC web UI → websockify → x11vnc (phone browser, no VNC app required).
  systemd.services.hermes-browser-novnc = {
    description = "Hermes browser noVNC (phone captcha handoff)";
    wantedBy = [ "multi-user.target" ];
    after = [ "hermes-browser-vnc.service" ];
    requires = [ "hermes-browser-vnc.service" ];

    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      Restart = "on-failure";
      RestartSec = 3;
      StandardOutput = "append:${logDir}/novnc.stdout";
      StandardError = "append:${logDir}/novnc.stderr";
    };

    # novnc web root: prefer share/novnc (nixpkgs), fall back to share/webapps/novnc.
    script = ''
      set -euo pipefail
      webroot=""
      for d in \
        ${pkgs.novnc}/share/novnc \
        ${pkgs.novnc}/share/webapps/novnc \
        ${pkgs.novnc}/share/novnc/www
      do
        if [[ -d "$d" ]]; then webroot="$d"; break; fi
      done
      if [[ -z "$webroot" ]]; then
        echo "novnc web root not found under ${pkgs.novnc}" >&2
        ls -la ${pkgs.novnc}/share || true
        exit 1
      fi
      exec ${pkgs.python3Packages.websockify}/bin/websockify \
        --web "$webroot" \
        0.0.0.0:${toString novncPort} \
        127.0.0.1:${toString vncPort}
    '';
  };
}
