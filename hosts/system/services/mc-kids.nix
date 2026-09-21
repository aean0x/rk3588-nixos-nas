# Family Minecraft: Paper 26.2 + Geyser-Spigot + Floodgate-Spigot.
# One JVM. Java clients on TCP 25565, Bedrock (phones) on UDP 19132 via Geyser.
# Geyser only translates I/O; the world is simulated once. Gamerules and these
# datapacks apply to Bedrock the same as Java. No client-required Fabric mods,
# no Bedrock behavior packs, no Docker, no MSH (a RakNet ping cannot wake a
# Java-only sleep proxy). Always-on for after-school play.
#
# Do not enable this and bta-server.nix at the same time: they share :25565
# and the 8 GiB box cannot host both RAM caps.
#
# Pin Paper + Geyser + Floodgate together in one commit after a store update.
# `:latest` URLs are how you get a Friday-night join failure.
#
# Hostname. Clients join at minecraft.<domain> (LAN AdGuard rewrite and
# Tailscale grey-cloud *.<domain>). Not Caddy, not the Cloudflare tunnel.
# Java: TCP 25565. Bedrock: UDP 19132. No WAN path (Starlink CGNAT).
#
# Auth. online-mode=true. Floodgate lets Bedrock in via Xbox Live; those
# usernames get a `.` prefix. Whitelist the Floodgate UUID from the join log,
# not a guessed Java UUID. Seed whitelist/ops with the Java account only;
# runtime `/whitelist add` is kept (we do not rewrite those files if present).
#
# Kid-mode. `world/datapacks/kidmode-gamerules` is the unlock panel (load.mcfunction).
# `world/datapacks/kidmode` is a saturation loop; delete that pack when food
# should matter. Peaceful already stops Java hunger; Bedrock-through-Geyser
# lives in the Java simulation, so they get it too.
#
# Console. FIFO stdin, same shape as the original BTA unit.
#   echo whitelist add .Player > /run/mc-kids.stdin
# `systemctl stop mc-kids` writes `stop` and waits for a clean save.
{
  pkgs,
  lib,
  settings,
  ...
}:
let
  mcVersion = "26.2";
  paperBuild = 126;
  geyserVersion = "2.11.3";
  geyserBuild = 1245;
  floodgateVersion = "2.2.5";
  floodgateBuild = 141;

  javaPort = 25565;
  bedrockPort = 19132;
  host = "minecraft.${settings.domain}";
  dataDir = "/var/lib/mc-kids";
  fifo = "/run/mc-kids.stdin";

  # Paper 26.2 toolchain is Java 25 (paper-api README). 21 is not enough.
  jre = pkgs.jdk25_headless;

  paper = pkgs.fetchurl {
    url = "https://fill-data.papermc.io/v1/objects/9c95eb088b903d9ed96cd457838f3078f02407a965dc8ae36d2c4e551a04355a/paper-${mcVersion}-${toString paperBuild}.jar";
    hash = "sha256-nJXrCIuQPZ7ZbNRXg48wePAkB6ll3IrjbSxOVRoENVo=";
  };

  geyser = pkgs.fetchurl {
    name = "Geyser-Spigot-${geyserVersion}-b${toString geyserBuild}.jar";
    url = "https://download.geysermc.org/v2/projects/geyser/versions/${geyserVersion}/builds/${toString geyserBuild}/downloads/spigot";
    hash = "sha256-2aO47vWZcmJDo/A8x2zDOHEn0q1I2q4AuGDAGJmVJ3o=";
  };

  floodgate = pkgs.fetchurl {
    name = "floodgate-spigot-${floodgateVersion}-b${toString floodgateBuild}.jar";
    url = "https://download.geysermc.org/v2/projects/floodgate/versions/${floodgateVersion}/builds/${toString floodgateBuild}/downloads/spigot";
    hash = "sha256-IVcK/5zhfWmDko6FUnd3YOHt5QUAJrBMaGsK4RLm/X4=";
  };

  jvmOpts = [
    "-Xms512M"
    "-Xmx2G"
  ];

  # Mojang UUID for the Java account that already plays here. Floodgate UUIDs
  # are added at runtime after the first Bedrock join.
  javaPlayer = {
    name = "0xAean";
    uuid = "784e1c66-f3f7-4e2e-8793-6e100f249e0a";
  };

  serverProperties = {
    motd = host;
    server-port = javaPort;
    max-players = 8;
    view-distance = 8;
    simulation-distance = 6;
    online-mode = true;
    white-list = true;
    enforce-whitelist = true;
    difficulty = "peaceful";
    allow-flight = true;
    spawn-protection = 16;
  };

  serverPropertiesFile = pkgs.writeText "mc-kids-server.properties" (
    "# server.properties managed by NixOS - edit hosts/system/services/mc-kids.nix\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: value: "${name}=${if lib.isBool value then lib.boolToString value else toString value}"
      ) serverProperties
    )
    + "\n"
  );

  eulaFile = pkgs.writeText "eula.txt" "eula=true\n";

  whitelistFile = pkgs.writeText "whitelist.json" (
    builtins.toJSON [
      {
        uuid = javaPlayer.uuid;
        name = javaPlayer.name;
      }
    ]
  );

  opsFile = pkgs.writeText "ops.json" (
    builtins.toJSON [
      {
        uuid = javaPlayer.uuid;
        name = javaPlayer.name;
        level = 4;
        bypassesPlayerLimit = true;
      }
    ]
  );

  packMcmeta = desc: {
    pack = {
      description = desc;
      min_format = [
        107
        1
      ];
      max_format = 107;
    };
  };

  tickMcfunction = pkgs.writeText "tick.mcfunction" "effect give @a minecraft:saturation 8 0 true\n";

  loadMcfunction = pkgs.writeText "load.mcfunction" ''
    difficulty peaceful
    gamerule pvp false
    gamerule keep_inventory true
    gamerule mob_griefing false
    gamerule spawn_phantoms false
    gamerule spawn_patrols false
    gamerule spawn_wandering_traders false
    gamerule raids false
    gamerule immediate_respawn true
    gamerule fall_damage false
    gamerule players_sleeping_percentage 1
  '';

  # Hunger is not a gamerule. Peaceful stops Java drain; this keeps Bedrock
  # players (same Java simulation) topped up. Remove the pack when food matters.
  kidmodeDatapack = pkgs.runCommand "kidmode-datapack" { } ''
    mkdir -p $out/data/kidmode/function $out/data/minecraft/tags/function
    cp ${pkgs.writeText "pack.mcmeta" (builtins.toJSON (packMcmeta "Kid-mode saturation (delete when food should matter)"))} $out/pack.mcmeta
    cp ${pkgs.writeText "tick.json" (builtins.toJSON { values = [ "kidmode:tick" ]; })} $out/data/minecraft/tags/function/tick.json
    cp ${tickMcfunction} $out/data/kidmode/function/tick.mcfunction
  '';

  # Unlock panel: comment or delete lines as he grows, then rebuild / restart
  # or `/function kidmode:load`.
  kidmodeGamerules = pkgs.runCommand "kidmode-gamerules-datapack" { } ''
    mkdir -p $out/data/kidmode/function $out/data/minecraft/tags/function
    cp ${pkgs.writeText "pack.mcmeta" (builtins.toJSON (packMcmeta "Kid-mode gamerules (unlock panel)"))} $out/pack.mcmeta
    cp ${pkgs.writeText "load.json" (builtins.toJSON { values = [ "kidmode:load" ]; })} $out/data/minecraft/tags/function/load.json
    cp ${loadMcfunction} $out/data/kidmode/function/load.mcfunction
  '';

  stopScript = pkgs.writeShellScript "mc-kids-stop" ''
    echo stop > ${fifo}
    while kill -0 "$1" 2> /dev/null; do
      sleep 1
    done
  '';
in
{
  users.users.mc-kids = {
    description = "Family Minecraft (Paper + Geyser)";
    isSystemUser = true;
    group = "mc-kids";
  };

  users.groups.mc-kids = { };

  systemd.sockets.mc-kids = {
    bindsTo = [ "mc-kids.service" ];
    socketConfig = {
      ListenFIFO = fifo;
      SocketMode = "0660";
      SocketUser = "mc-kids";
      SocketGroup = "mc-kids";
      RemoveOnStop = true;
      FlushPending = true;
    };
  };

  systemd.services.mc-kids = {
    description = "Family Minecraft (Paper ${mcVersion} + Geyser + Floodgate)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "mc-kids.socket" ];
    after = [
      "network-online.target"
      "mc-kids.socket"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "mc-kids";
      Group = "mc-kids";
      StateDirectory = "mc-kids";
      WorkingDirectory = dataDir;
      # paper.jar is copied into StateDirectory: Paperclip writes next to the jar.
      ExecStart = "${jre}/bin/java ${lib.escapeShellArgs jvmOpts} -jar paper.jar nogui";
      ExecStop = "${stopScript} $MAINPID";
      Restart = "on-failure";
      RestartSec = "15s";
      TimeoutStopSec = "180s";

      StandardInput = "socket";
      StandardOutput = "journal";
      StandardError = "journal";

      MemoryHigh = "2.5G";
      MemoryMax = "3G";
      MemorySwapMax = "2G";
      # Below Hermes (+500). AdGuard/HA stay preferred (-500).
      OOMScoreAdjust = 100;

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

    preStart = ''
      cp -f ${serverPropertiesFile} server.properties
      chmod u+w server.properties
      cp -f ${eulaFile} eula.txt
      cp -f ${paper} paper.jar
      chmod u+w paper.jar
      mkdir -p plugins world/datapacks
      ln -sfn ${geyser} plugins/Geyser-Spigot.jar
      ln -sfn ${floodgate} plugins/floodgate-spigot.jar
      # Paper refuses store symlinks under world/ (ContentValidationException).
      rm -rf world/datapacks/kidmode world/datapacks/kidmode-gamerules
      cp -a ${kidmodeDatapack} world/datapacks/kidmode
      cp -a ${kidmodeGamerules} world/datapacks/kidmode-gamerules
      chmod -R u+w world/datapacks/kidmode world/datapacks/kidmode-gamerules
      if [ ! -e whitelist.json ]; then
        cp ${whitelistFile} whitelist.json
        chmod u+w whitelist.json
      fi
      if [ ! -e ops.json ]; then
        cp ${opsFile} ops.json
        chmod u+w ops.json
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [ javaPort ];
  networking.firewall.allowedUDPPorts = [ bedrockPort ];
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ javaPort ];
  networking.firewall.interfaces.tailscale0.allowedUDPPorts = [ bedrockPort ];
}
