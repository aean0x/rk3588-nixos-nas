# Parked. Import is commented in services.nix so Paper (minecraft.nix) can own
# :25565 and the RAM. World stays in /var/lib/bta-server; no Nix oneshot
# deletes it. Re-enable by swapping the minecraft import for this one — do
# not run both (port + 8 GiB host).
#
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
#   - Paper/Bukkit empty-server plugins (EmptyServerStopper, NoPlayerShutdown)
#     do not exist for BTA. Sleep has to sit outside the jar.
#
# Sleep proxy. systemd runs [MSH](https://github.com/gekware/minecraft-server-hibernation)
# (nixpkgs `minecraft-server-hibernation`) always-on, a few MB. It holds the
# public join port. Java is dead until the first TCP client; last player gone +
# TimeBeforeStoppingEmptyServer later, MSH writes `stop` on the jar's stdin
# (clean save). StopServerAllowKill is -1: MSH never SIGKILLs Java.
#   Public:  MSH :25565 (LAN + Tailscale). Player-facing hostname unchanged.
#   Private: BTA :25566 on 127.0.0.1. Not firewalled, not LAN-reachable.
#   Do not socket-activate Java (`LISTEN_FDS` is unused by Minecraft).
#   lazymc / mcsleepingserverstarter speak modern protocol; BTA is protocol 14.
#   Stock MSH only WarmMS()s a modern handshake, so we patch unknown packets
#   (Beta 0xFE ping / 0x02 handshake) as JOIN. Asleep MOTD is generic; join
#   twice after the ~10-20 s boot if the first attempt races the jar.
#
# Verified against this artifact (v8.0.1):
#   - boots with `--nogui`, accepts `stop` on stdin, saves the world, exits rc=0;
#   - `--nogui` is mandatory - without it the jar opens an AWT ServerGui window and
#     the NAS has no X server;
#   - needs JRE 21: the jar carries class files up to major 65 (the
#     net/minecraft/datagen tools). The wiki's "OpenJDK 17 recommended" predates 8.0;
#   - bundled log4j is 2.19.0 (Log4Shell-fixed);
#   - logs `Done (` / `Stopping the server` in log4j form, which stock MSH already
#     treats as ONLINE / STOPPING.
#
# Memory. AdGuard + Home Assistant still outrank everything. The world in
# /var/lib/bta-server/world outranks Hermes: a mid-save cgroup OOM corrupts
# the map, an agent OOM just respawns. MemoryMax keeps the working set from
# eating the host; MemorySwapMax is the burst so a save pages instead of dying.
#   Measured on this jar: with the heap fully committed (-Xms768M -Xmx768M) the
#   process settles at ~917 MiB RSS, i.e. ~150 MiB of metaspace, code cache,
#   threads and direct buffers on top of the heap. -Xmx768M under a 1G RAM cap
#   therefore leaves ~107 MiB of slack, and MemoryHigh sits above the measured
#   ceiling so normal play is never throttled. MSH itself is a few MB inside
#   the same cgroup.
#   Raising -Xmx requires raising MemoryMax with it.
#
# Hostname. Clients join at minecraft.<domain>:25565 (LAN AdGuard rewrite and
# Tailscale grey-cloud *.<domain>). Not Caddy, not the Cloudflare tunnel: the
# protocol is TCP 25565, not HTTP. Do not add proxyServices or externalHosts.
#
# Console. MSH owns Java stdin. `systemctl stop bta-server` SIGTERMs MSH, which
# writes `stop` and waits for the child. --kill-whom=main is mandatory: a
# cgroup-wide SIGUSR1/2 is the default for `systemctl kill` and the JVM treats
# those as fatal. Wake / hibernate without a client:
#   systemctl kill -s SIGUSR2 --kill-whom=main bta-server
#   systemctl kill -s SIGUSR1 --kill-whom=main bta-server
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
  settings,
  ...
}:
let
  version = "8.0.1";
  publicPort = 25565;
  servPort = 25566;
  host = "minecraft.${settings.domain}";
  dataDir = "/var/lib/bta-server";
  jarName = "bta-server.jar";
  idleStopSeconds = 600;

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

  # Stock MSH only WarmMS()s a modern handshake and os.Exits after 1s if it has
  # not already parsed STOPPING. Patch unknown packets as JOIN (Beta 0xFE / 0x02)
  # and wait for the Java child on SIGTERM so StopServerAllowKill=-1 is real.
  msh = pkgs.minecraft-server-hibernation.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./msh-bta-legacy-join.patch ];
  });

  # Heap stays below MemoryMax on purpose; see the memory note above.
  jvmOpts = [
    "-Xms512M"
    "-Xmx768M"
  ];

  # Only keys that must not drift from the server's own defaults are pinned:
  # server-port is the private loopback port MSH dials (must differ from
  # MshPort), view-distance/max-players bound a 2-core 1 GiB service, and
  # online-mode=false lets family clients join. The server fills in every other
  # key and rewrites this file on each Java start.
  # To restrict who may join, add `white-list = true;` here and list the player
  # names, one per line, in /var/lib/bta-server/white-list.txt (beta-era text
  # format, not whitelist.json).
  serverProperties = {
    motd = host;
    server-port = servPort;
    server-ip = "127.0.0.1";
    max-players = 10;
    view-distance = 12;
    online-mode = false;
    difficulty = 1;
    mob-griefing = 0;
    level-seed = "JASON";
    spawn-monsters = false;
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

  # Dummy eula.txt: BTA has no EULA codepath, but stock MSH will auto-start the
  # jar on load if this file is missing, then SetMajorError and refuse WarmMS.
  eulaFile = pkgs.writeText "eula.txt" "eula=true\n";

  # Protocol 14 is Beta 1.7.3 (wiki.vg). Used only for the asleep fake ping;
  # the jar has no version.json, so MSH will not overwrite this. The asleep
  # MOTD is still a modern JSON ping and will look generic to a Beta client.
  mshConfig = {
    Server = {
      Folder = dataDir;
      FileName = jarName;
      Version = "b1.7.3";
      Protocol = 14;
    };
    Commands = {
      StartServer = "${jre}/bin/java <Commands.StartServerParam> -jar <Server.FileName> --nogui";
      StartServerParam = lib.concatStringsSep " " jvmOpts;
      StopServer = "stop";
      StopServerAllowKill = -1;
    };
    Msh = {
      Debug = 2;
      ID = "";
      MshPort = publicPort;
      MshPortQuery = publicPort;
      EnableQuery = false;
      TimeBeforeStoppingEmptyServer = idleStopSeconds;
      SuspendAllow = false;
      SuspendRefresh = -1;
      InfoHibernation = "                   §fserver status:\n                   §b§lHIBERNATING";
      InfoStarting = "                   §fserver status:\n                    §6§lWARMING UP";
      NotifyUpdate = false;
      NotifyMessage = false;
      Whitelist = [ ];
      WhitelistImport = false;
      ShowResourceUsage = false;
      ShowInternetUsage = false;
    };
  };

  mshConfigFile = pkgs.writeText "msh-config.json" (builtins.toJSON mshConfig);
in
{
  users.users.bta-server = {
    description = "Better than Adventure! server";
    isSystemUser = true;
    group = "bta-server";
  };

  users.groups.bta-server = { };

  systemd.services.bta-server = {
    description = "Better than Adventure! server (Minecraft Beta 1.7.3 fork)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # LookPath("java") at MSH load; the StartServer command uses the absolute JRE.
    path = [ jre ];

    serviceConfig = {
      Type = "simple";
      User = "bta-server";
      Group = "bta-server";
      StateDirectory = "bta-server";
      WorkingDirectory = dataDir;
      ExecStart = "${lib.getExe msh}";
      Restart = "on-failure";
      RestartSec = "15s";
      # A stop has to flush the world to disk on ARM and 2 cores.
      TimeoutStopSec = "180s";
      # SIGTERM only the MSH main process. MSH writes `stop` to Java; mixed
      # mode avoids a simultaneous SIGTERM to the JVM while it is saving.
      KillMode = "mixed";

      StandardOutput = "journal";
      StandardError = "journal";

      MemoryHigh = "960M";
      MemoryMax = "1G";
      # 2G swap on top of 1G RAM: a save that spikes pages instead of taking a
      # cgroup OOM (which would drop the world). Host swap is 8G; burst is fine.
      MemorySwapMax = "2G";
      # Below Hermes (+500) so host pressure kills the agent first. Still
      # positive, so AdGuard/HA (-500) stay preferred.
      OOMScoreAdjust = 100;

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

    # Declarative server.properties / msh-config.json: MSH Save()s its ID into
    # msh-config.json, and the jar merges defaults into server.properties on
    # each Java start, so the pinned keys are rewritten here every MSH start.
    preStart = ''
      cp -f ${serverPropertiesFile} server.properties
      chmod u+w server.properties
      ln -sfn ${jar} ${jarName}
      cp -f ${eulaFile} eula.txt
      cp -f ${mshConfigFile} msh-config.json
      chmod u+w msh-config.json
    '';
  };

  networking.firewall.allowedTCPPorts = [ publicPort ];
  # Tailscale interface list is additive; without this a phone on the tailnet
  # using public DNS still hits the grey-cloud A, but the default tailscale0
  # allow-list is only 80/443.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ publicPort ];
}
