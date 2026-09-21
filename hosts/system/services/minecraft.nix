# Family Minecraft: Paper + Geyser-Spigot + Floodgate-Spigot.
# One JVM. Java clients on TCP 25565, Bedrock (phones) on UDP 19132 via Geyser.
# Geyser only translates I/O; the world is simulated once. Gamerules and these
# datapacks apply to Bedrock the same as Java. No client-required Fabric mods,
# no Bedrock behavior packs, no Docker, no MSH (a RakNet ping cannot wake a
# Java-only sleep proxy). Always-on for after-school play.
#
# Do not enable this and bta-server.nix at the same time: they share :25565
# and the 8 GiB box cannot host both RAM caps.
#
# Jars are not pinned. Each start refreshes latest Paper with a STABLE
# channel build (skips rc/pre/alpha names and ALPHA-only lines such as
# 26.3 while Geyser still speaks 26.2) plus Geyser/Floodgate
# `versions/latest/builds/latest`. If an API is down, existing jars are
# kept so after-school play still boots.
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
#   echo whitelist add .Player > /run/minecraft.stdin
# `systemctl stop minecraft` writes `stop` and waits for a clean save.
{
  pkgs,
  lib,
  settings,
  ...
}:
let
  javaPort = 25565;
  bedrockPort = 19132;
  host = "minecraft.${settings.domain}";
  dataDir = "/var/lib/minecraft";
  fifo = "/run/minecraft.stdin";

  # Paper 26.1+ toolchain is Java 25 (paper-api README). 21 is not enough.
  jre = pkgs.jdk25_headless;

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

  serverPropertiesFile = pkgs.writeText "minecraft-server.properties" (
    "# server.properties managed by NixOS - edit hosts/system/services/minecraft.nix\n"
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

  # Wide range so a Paper bump does not reject the pack. Unlock panel is the
  # gamerule list below; comment lines there as he grows.
  packMcmeta = desc: {
    pack = {
      description = desc;
      pack_format = 48;
      min_format = 1;
      max_format = 999;
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

  kidmodeGamerules = pkgs.runCommand "kidmode-gamerules-datapack" { } ''
    mkdir -p $out/data/kidmode/function $out/data/minecraft/tags/function
    cp ${pkgs.writeText "pack.mcmeta" (builtins.toJSON (packMcmeta "Kid-mode gamerules (unlock panel)"))} $out/pack.mcmeta
    cp ${pkgs.writeText "load.json" (builtins.toJSON { values = [ "kidmode:load" ]; })} $out/data/minecraft/tags/function/load.json
    cp ${loadMcfunction} $out/data/kidmode/function/load.mcfunction
  '';

  ua = "rk3588-nixos-nas/minecraft (https://github.com/aean0x/rk3588-nixos-nas)";

  updateJars = pkgs.writeShellScript "minecraft-update-jars" ''
    set -euo pipefail
    UA=${lib.escapeShellArg ua}
    STAMP=jars.stamp

    api() {
      ${pkgs.curl}/bin/curl -fsSL --retry 3 --retry-delay 2 -A "$UA" "$@"
    }

    download() {
      ${pkgs.curl}/bin/curl -fL --retry 3 --retry-delay 2 -A "$UA" -o "$2.part" "$1"
      mv -f "$2.part" "$2"
    }

    have=$(cat "$STAMP" 2>/dev/null || true)
    want=

    paper_json=$(api https://fill.papermc.io/v3/projects/paper || true)
    paper_versions=$(echo "$paper_json" | ${pkgs.jq}/bin/jq -r '
      .versions | to_entries[] | .value[] | select(test("rc|pre|snapshot|beta"; "i") | not)
    ' 2>/dev/null || true)
    paper_id=
    paper_url=
    for paper_version in $paper_versions; do
      builds=$(api "https://fill.papermc.io/v3/projects/paper/versions/''${paper_version}/builds" || true)
      [ -n "$builds" ] || continue
      paper_url=$(echo "$builds" | ${pkgs.jq}/bin/jq -r '
        first(.[] | select(.channel == "STABLE") | .downloads["server:default"].url) // empty
      ' 2>/dev/null || true)
      if [ -n "$paper_url" ]; then
        paper_id=$(echo "$builds" | ${pkgs.jq}/bin/jq -r --arg ver "$paper_version" '
          first(.[] | select(.channel == "STABLE")) | "paper-\($ver)-\(.id)"
        ')
        break
      fi
    done
    if [ -z "$paper_url" ]; then
      echo "minecraft: no Paper STABLE build found"
    else
      want="''${want}"$'\n'"paper=''${paper_id}"
      if [ ! -s paper.jar ] || ! echo "$have" | grep -qx "paper=''${paper_id}"; then
        echo "minecraft: fetching $paper_id"
        if download "$paper_url" paper.jar; then
          chmod u+w paper.jar
        else
          echo "minecraft: Paper fetch failed; keeping existing jar if any"
        fi
      fi
    fi

    geyser_meta=$(api https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest || true)
    if [ -n "$geyser_meta" ]; then
      geyser_id=$(echo "$geyser_meta" | ${pkgs.jq}/bin/jq -r '"geyser-\(.version)-b\(.build)"' || true)
      want="''${want}"$'\n'"geyser=''${geyser_id}"
      if [ ! -s plugins/Geyser-Spigot.jar ] || ! echo "$have" | grep -qx "geyser=''${geyser_id}"; then
        echo "minecraft: fetching $geyser_id"
        mkdir -p plugins
        download https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot plugins/Geyser-Spigot.jar \
          || echo "minecraft: Geyser fetch failed; keeping existing jar if any"
      fi
    fi

    floodgate_meta=$(api https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest || true)
    if [ -n "$floodgate_meta" ]; then
      floodgate_id=$(echo "$floodgate_meta" | ${pkgs.jq}/bin/jq -r '"floodgate-\(.version)-b\(.build)"' || true)
      want="''${want}"$'\n'"floodgate=''${floodgate_id}"
      if [ ! -s plugins/floodgate-spigot.jar ] || ! echo "$have" | grep -qx "floodgate=''${floodgate_id}"; then
        echo "minecraft: fetching $floodgate_id"
        mkdir -p plugins
        download https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot plugins/floodgate-spigot.jar \
          || echo "minecraft: Floodgate fetch failed; keeping existing jar if any"
      fi
    fi

    if [ ! -s paper.jar ]; then
      echo "minecraft: paper.jar missing and latest fetch failed" >&2
      exit 1
    fi
    if [ ! -s plugins/Geyser-Spigot.jar ] || [ ! -s plugins/floodgate-spigot.jar ]; then
      echo "minecraft: Geyser/Floodgate jar missing and latest fetch failed" >&2
      exit 1
    fi

    printf '%s\n' "$want" | sed '/^$/d' > "$STAMP"
  '';

  stopScript = pkgs.writeShellScript "minecraft-stop" ''
    echo stop > ${fifo}
    while kill -0 "$1" 2> /dev/null; do
      sleep 1
    done
  '';
in
{
  users.users.minecraft = {
    description = "Minecraft (Paper + Geyser)";
    isSystemUser = true;
    group = "minecraft";
  };

  users.groups.minecraft = { };

  systemd.sockets.minecraft = {
    bindsTo = [ "minecraft.service" ];
    socketConfig = {
      ListenFIFO = fifo;
      SocketMode = "0660";
      SocketUser = "minecraft";
      SocketGroup = "minecraft";
      RemoveOnStop = true;
      FlushPending = true;
    };
  };

  systemd.services.minecraft = {
    description = "Minecraft (Paper + Geyser + Floodgate)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "minecraft.socket" ];
    after = [
      "network-online.target"
      "minecraft.socket"
    ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
    ];

    serviceConfig = {
      Type = "simple";
      User = "minecraft";
      Group = "minecraft";
      StateDirectory = "minecraft";
      WorkingDirectory = dataDir;
      # paper.jar is copied into StateDirectory: Paperclip writes next to the jar.
      ExecStart = "${jre}/bin/java ${lib.escapeShellArgs jvmOpts} -jar paper.jar nogui";
      ExecStop = "${stopScript} $MAINPID";
      Restart = "on-failure";
      RestartSec = "15s";
      TimeoutStartSec = "300s";
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
      mkdir -p plugins world/datapacks
      ${updateJars}
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
