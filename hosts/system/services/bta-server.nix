# Better than Adventure! (BTA) multiplayer server - native systemd service.
# BTA is an unofficial fork of Minecraft Beta 1.7.3, shipped as one fat server jar.
#
# Why not the two obvious alternatives:
#   - nixpkgs' `services.minecraft-server` assumes a vanilla layout: it asserts
#     Mojang's EULA and manages `eula.txt` / `whitelist.json`. This jar has no EULA
#     codepath at all (no `eula` string in its class constant pool) and uses
#     beta-era `white-list.txt` / `ops.txt` / `banned-players.txt`.
#   - A container would mean a third-party image (itzg TYPE=CUSTOM) on a `:latest`
#     treadmill around one jar plus a JRE. Repo philosophy reserves Docker for
#     dependency-heavy stacks.
#
# Verified against this artifact (v8.0.1):
#   - boots with `--nogui`, accepts `stop` on stdin, saves the world, exits rc=0;
#   - `--nogui` is mandatory - without it the jar opens an AWT ServerGui window and
#     the NAS has no X server;
#   - needs JRE 21: the jar carries class files up to major 65 (the
#     net/minecraft/datagen tools). The wiki's "OpenJDK 17 recommended" predates 8.0;
#   - bundled log4j is 2.19.0 (Log4Shell-fixed).
#
# Memory. The host runs 8 GiB fully committed (AdGuard + Home Assistant outrank
# everything, Hermes is tertiary), so MemoryMax is the hard ceiling: an overrun
# kills this game server, never the DNS resolver or the automation stack.
#   Measured on this jar: with the heap fully committed (-Xms768M -Xmx768M) the
#   process settles at ~917 MiB RSS, i.e. ~150 MiB of metaspace, code cache,
#   threads and direct buffers on top of the heap. -Xmx768M under a 1G cap
#   therefore leaves ~107 MiB of slack, and MemoryHigh sits above the measured
#   ceiling so normal play is never throttled.
#   Raising -Xmx requires raising MemoryMax with it, or the cgroup OOM killer takes
#   the JVM down mid-save (the world lives in /var/lib/bta-server/world).
#
# Console. The server reads commands from stdin, so the unit takes stdin from a
# FIFO (the shape nixpkgs' minecraft-server uses). `systemctl stop bta-server`
# writes `stop` and waits for a clean save. A one-off command is
#   echo list > /run/bta-server.stdin
#
# Reachable on TCP 25565 over the LAN and Tailscale only. There is no WAN path
# (Starlink CGNAT cannot accept inbound), which is why the server runs
# offline-mode. Set online-mode = true in `serverProperties` before exposing it.
#
# `default-gamemode` is deliberately not pinned: in 8.0.1 the property is parsed
# before the gamemode registry is populated, so every value - including the
# server's own `minecraft:gamemode/survival` default - logs "Unrecognised
# gamemode" and cannot take effect. Left to the server until upstream reorders it.
{
  pkgs,
  lib,
  ...
}:
let
  version = "8.0.1";
  port = 25565;
  dataDir = "/var/lib/bta-server";
  fifo = "/run/bta-server.stdin";

  # headless JDK is what nixpkgs itself uses for Minecraft servers
  # (javaPackages.compiler.openjdkNN.headless in pkgs/by-name/mi/minecraft-server).
  jre = pkgs.jdk21_headless;

  # Pinned by content hash, not by version string: the CDN is Cloudflare-fronted,
  # so a republished tag has to fail the build instead of silently changing what
  # runs. Bump `version` and `hash` together:
  #   nix-prefetch-url https://downloads.betterthanadventure.net/bta-server/release/v<v>/bta.v<v>.server.jar
  jar = pkgs.fetchurl {
    url = "https://downloads.betterthanadventure.net/bta-server/release/v${version}/bta.v${version}.server.jar";
    hash = "sha256-ihSLgO5x9UwyiloLnUhZ7W/1MQ0zF0BaFOdDV9qUAQY=";
  };

  # Heap stays below MemoryMax on purpose; see the memory note above.
  jvmOpts = [
    "-Xms512M"
    "-Xmx768M"
  ];

  # Only keys that must not drift from the server's own defaults are pinned:
  # server-port has to match the firewall rule, view-distance/max-players bound a
  # 2-core 1 GiB service, and online-mode=false lets family clients join. The
  # server fills in every other key and rewrites this file on each start.
  # To restrict who may join, add `white-list = true;` here and list the player
  # names, one per line, in /var/lib/bta-server/white-list.txt (beta-era text
  # format, not whitelist.json).
  serverProperties = {
    motd = "Better than Adventure server - rocknas";
    server-port = port;
    max-players = 10;
    view-distance = 8;
    online-mode = false;
  };

  serverPropertiesFile = pkgs.writeText "bta-server.properties" (
    "# server.properties managed by NixOS - edit hosts/system/services/bta-server.nix\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: value: "${name}=${if lib.isBool value then lib.boolToString value else toString value}"
      ) serverProperties
    )
    + "\n"
  );

  stopScript = pkgs.writeShellScript "bta-server-stop" ''
    echo stop > ${fifo}
    while kill -0 "$1" 2> /dev/null; do
      sleep 1
    done
  '';
in
{
  users.users.bta-server = {
    description = "Better than Adventure! server";
    isSystemUser = true;
    group = "bta-server";
  };

  users.groups.bta-server = { };

  systemd.sockets.bta-server = {
    bindsTo = [ "bta-server.service" ];
    socketConfig = {
      ListenFIFO = fifo;
      SocketMode = "0660";
      SocketUser = "bta-server";
      SocketGroup = "bta-server";
      RemoveOnStop = true;
      FlushPending = true;
    };
  };

  systemd.services.bta-server = {
    description = "Better than Adventure! server (Minecraft Beta 1.7.3 fork)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "bta-server.socket" ];
    after = [
      "network-online.target"
      "bta-server.socket"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "bta-server";
      Group = "bta-server";
      StateDirectory = "bta-server";
      WorkingDirectory = dataDir;
      ExecStart = "${jre}/bin/java ${lib.escapeShellArgs jvmOpts} -jar ${jar} --nogui";
      ExecStop = "${stopScript} $MAINPID";
      Restart = "on-failure";
      RestartSec = "15s";
      # A stop has to flush the world to disk on ARM and 2 cores.
      TimeoutStopSec = "180s";

      StandardInput = "socket";
      StandardOutput = "journal";
      StandardError = "journal";

      MemoryHigh = "960M";
      MemoryMax = "1G";
      MemorySwapMax = "512M";
      # Tertiary vs AdGuard/Home Assistant: under host pressure the kernel should
      # pick this service first.
      OOMScoreAdjust = 400;

      # Hardening follows nixpkgs' minecraft-server shape - the same
      # JVM-in-a-systemd-unit workload. MemoryDenyWriteExecute is deliberately
      # absent: the JIT needs writable and executable mappings.
      CapabilityBoundingSet = [ "" ];
      DeviceAllow = [ "" ];
      LockPersonality = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      UMask = "0007";
    };

    # Declarative server.properties: the server merges its own defaults into this
    # file on every start, so the pinned keys always win.
    preStart = ''
      cp -f ${serverPropertiesFile} server.properties
      chmod u+w server.properties
    '';
  };

  networking.firewall.allowedTCPPorts = [ port ];
}
