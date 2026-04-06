{
  pkgs,
  oc,
  lib,
  ...
}:
let
  packages = import ./packages.nix { inherit lib; };

  # ── Typed step generators (all the meat stays here)
  mkStep =
    step:
    let
      pkg = step.package or step.name;
      typeHandlers = {
        apt = ''
          # === ${step.name} ===
          RUN rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* && \
              apt-get update && \
              apt-get install -y --no-install-recommends ${builtins.concatStringsSep " " step.packages} && \
              rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
        '';

        tarball =
          let
            stripFlag = lib.optionalString (
              step ? stripComponents && step.stripComponents > 0
            ) " --strip-components=${toString step.stripComponents}";
          in
          ''
            # === ${step.name} (tarball) ===
            RUN curl -fsSL ${step.url} | tar -xzf -${stripFlag} -C /usr/local/bin && \
                find /usr/local/bin -type f -executable -exec chmod +x {} + 2>/dev/null || true
          '';

        npm = ''
          # === ${step.name} (npm) ===
          ${
            if step ? env then
              "ENV ${lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") step.env)}\n"
            else
              ""
          }RUN npm install -g --force ${pkg}
          ${if step ? post && step.post != "" then "RUN ${step.post}" else ""}
        '';

        pnpm = ''
          # === ${step.name} (pnpm) ===
          ${
            if step ? env then
              "ENV " + lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") step.env) + "\n"
            else
              ""
          }
          RUN PNPM_HOME=/usr/local/bin pnpm add -g ${pkg}
          ${if step ? post && step.post != "" then "RUN ${step.post}" else ""}
        '';

        pip = ''
          # === ${step.name} ===
          RUN uv pip install --system --break-system-packages ${builtins.concatStringsSep " " step.packages}
        '';

        node-workspace = ''
          # === ${step.name} (node-workspace) ===
          ${
            if step ? env then
              "ENV " + lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") step.env) + "\n"
            else
              ""
          }
          RUN mkdir -p /opt/${step.name} && \
              echo '${
                builtins.toJSON { dependencies = step.packages; }
              }' > /opt/${step.name}/package.json && \
              cd /opt/${step.name} && \
              PNPM_HOME=/usr/local/bin pnpm install
          ENV NODE_PATH=/opt/${step.name}/node_modules
          RUN cd /opt/${step.name} && \
              for bin in node_modules/.bin/*; do \
                [ -e "$bin" ] || continue; \
                name=$(basename "$bin"); \
                target=$(readlink -f "$bin"); \
                printf '#!/bin/sh\nexec node "%s" "$@"\n' "$target" > "/usr/local/bin/$name"; \
                chmod +x "/usr/local/bin/$name"; \
              done
          ${if step ? post && step.post != "" then "RUN cd /opt/${step.name} && ${step.post}" else ""}
        '';

        custom = ''
          # === ${step.name} (custom) ===
          ${if step ? pre && step.pre != "" then "${step.pre}\n" else ""}RUN ${step.install}
          ${if step ? post && step.post != "" then "RUN ${step.post}\n" else ""}
        '';
      };
    in
    typeHandlers.${step.type or "custom"} or (throw "Unknown dependency type: ${step.type or "none"}");

  # Split by sandbox flag
  sharedSteps = lib.concatMapStrings mkStep (lib.filter (s: s.sandbox or true) packages.dependencies);

  gatewayOnlySteps = lib.concatMapStrings mkStep (
    lib.filter (s: !(s.sandbox or true)) packages.dependencies
  );

  commonSetup = ''
    USER root

    ${sharedSteps}

    # Common directory setup + git safe.directory
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
    ];
    requiredBy = [
      "docker-openclaw-gateway.service"
    ];
    path = [
      pkgs.docker
      pkgs.gnutar
      pkgs.coreutils
    ];
    script = ''
      BUILD_ARGS=""
      if [ -f /var/tmp/openclaw-force-rebuild ]; then
        echo "Force rebuild flag detected, bypassing Docker cache..."
        BUILD_ARGS="--no-cache"
        rm -f /var/tmp/openclaw-force-rebuild
      fi

      # ── Gateway image ──────────────────────────────────────────
      docker build --network=host $BUILD_ARGS -t ${oc.gatewayImage} - <<'GATEWAY_EOF'
      FROM ${oc.gatewayBaseImage}
      ${commonSetup}

      # Gateway-only dependencies
      ${gatewayOnlySteps}

      # Gateway-specific setup
      RUN groupadd -g 131 docker 2>/dev/null || true && usermod -aG docker node
      RUN mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial \
                   /var/tmp/openclaw-compile-cache && \
          chown 1000:1000 /var/tmp/openclaw-compile-cache && \
          chown -R _apt:root /var/lib/apt /var/cache/apt 2>/dev/null || true

      # OpenClaw CLI wrapper
      RUN printf '#!/bin/sh\nexec node /app/dist/index.js "$@"\n' > /usr/local/bin/openclaw && \
          chmod +x /usr/local/bin/openclaw

      USER 1000:1000
      GATEWAY_EOF

      # ── Sandbox image ──────────────────────────────────────────
      docker build --network=host $BUILD_ARGS -t ${oc.sandboxImage} - <<'SANDBOX_EOF'
      FROM ${oc.sandboxBaseImage}
      ${commonSetup}

      USER 1000:1000
      SANDBOX_EOF
    '';
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "3600";
    };
  };
}
