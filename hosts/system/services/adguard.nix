# AdGuard Home DNS (native NixOS)
#
# Hybrid declarative + UI model:
# - Core settings (upstreams, rewrites, base filters) stay in Nix.
# - mutableSettings = true allows UI changes to undeclared parts to persist
#   across restarts (Nix values still take precedence on merge).
# - "Kid profile" is a persistent client entry below + choice of global filters
#   + per-client toggles (parental, safe search, etc.).
# - For additive per-PC blocks without touching Nix: use Custom filtering rules
#   in the UI with the $client modifier (see bottom of file).
{
  settings,
  ...
}:
let
  port = 3000;
  lanIP = if (settings.enableRouter or false) then "192.168.2.1" else settings.network.address;
in
{
  services.caddy.proxyServices = {
    "adguard.${settings.domain}" = port;
  };

  # Critical path (LAN DNS). Prefer reclaim/kill of tertiary units first.
  systemd.services.adguardhome.serviceConfig = {
    OOMScoreAdjust = -500;
    MemoryMin = "128M";
  };

  services.adguardhome = {
    enable = true;
    mutableSettings = true;
    # Caddy fronts the UI. Binding *:3000 also opened an unauthenticated
    # control API on the LAN (users = []). Host-net jails still reach
    # loopback — set a UI password to close that remaining hole.
    host = "127.0.0.1";
    port = port;
    settings = {
      schema_version = 32;

      dns = {
        # Bind all IPv4 (incl. loopback). Host resolv uses 127.0.0.1 so hermes
        # and other local services hit this cache instead of public DNS direct.
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        # Upstream = public recursive only. Never 127.0.0.1 (recursion loop).
        upstream_dns = [
          settings.network.dnsPrimary
          settings.network.dnsSecondary
        ];
        bootstrap_dns = [
          "1.1.1.3"
          "1.0.0.3"
        ];
        # Real cache (nsncd hosts TTL is forced 0 — AGH is the only useful layer).
        cache_size = 64 * 1024 * 1024; # 64 MiB
        cache_ttl_min = 30;
        cache_optimistic = true;
        # Cron / agent storms can exceed default ~20 rps/client. 0 = disabled.
        # ratelimit_whitelist is []netip.Addr (single IPs only — CIDRs fatal).
        # Always declare explicitly so yaml-merge overwrites any poisoned work-dir list.
        ratelimit = 0;
        ratelimit_whitelist = [ "127.0.0.1" ];
      };

      # Kid lockdown profile: persistent client REQUIRES non-empty ids
      # (AdGuard fatals: "adding client: id required"). With mutableSettings,
      # omitting clients leaves any bad entry in /var/lib/AdGuardHome forever —
      # always declare persistent explicitly. Empty list clears poison on merge.
      # When ready: replace [] with a client that has real IP/MAC/hostname ids.
      clients = {
        persistent = [
          # {
          #   name = "toddler-pc";
          #   ids = [ "192.168.1.50" ]; # required
          #   tags = [ "kids" ];
          #   use_global_settings = false;
          #   filtering_enabled = true;
          #   parental_enabled = true;
          #   safebrowsing_enabled = true;
          #   safe_search = {
          #     enabled = true;
          #     bing = true;
          #     duckduckgo = true;
          #     google = true;
          #     youtube = true;
          #     yandex = true;
          #   };
          # };
        ];
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        rewrites_enabled = true;
        safebrowsing_enabled = false;
        parental_enabled = false;
        blocking_mode = "default";

        safe_search = {
          enabled = true;
          bing = true;
          duckduckgo = true;
          google = true;
          youtube = true;
          yandex = true;
        };

        rewrites = [
          {
            domain = settings.domain;
            answer = lanIP;
            enabled = true;
          }
          {
            domain = "*.${settings.domain}";
            answer = lanIP;
            enabled = true;
          }
        ];
      };

      # prettier-ignore
      filters = [
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
          name = "AdGuard DNS filter";
          id = 1;
        }
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
          name = "AdAway Default Blocklist";
          id = 2;
        }
        {
          enabled = true;
          url = "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-agh-online.txt";
          name = "Malware URL Blocklist";
          id = 3;
        }
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_44.txt";
          name = "Phishing URL Blocklist";
          id = 4;
        }
        # Kid-oriented safety list (bypass/VPNs, self-harm, predators, adult AI, gore, radicalization).
        # Use together with the per-client parental_enabled + custom $client rules.
        # Note: VPN-ish blocks hit apex tailscale.com → 0.0.0.0; allowlisted below.
        {
          enabled = true;
          url = "https://raw.githubusercontent.com/0xDarkMatter/aegis-blocklist/master/grades/standard.txt";
          name = "Aegis Child Safety (standard)";
          id = 5;
        }
      ];

      # Exception rules (adblock syntax). Aegis/VPN lists sinkhole the Tailscale
      # marketing apex; control plane hostnames often still resolve, but
      # tailscale.com → 0.0.0.0 breaks browser/docs and confuses tooling.
      user_rules = [
        "@@||tailscale.com^"
        "@@||ts.net^"
        "@@||tailscale.io^"
        # Aegis standard (filter id 5) is global and lists these two apex
        # names as exact host blocks. That sinkholes the official app/web
        # (discord.com → 0.0.0.0) while www/cdn/gateway still resolve.
        # Keep Aegis for the rest; re-block per kid client if needed:
        #   ||discord.com^$client='toddler-pc'
        "@@||discord.com^"
        "@@||discordapp.com^"
      ];
    };
  };

  # systemd-resolved conflicts with port 53 — AGH owns :53 on this host.
  services.resolved.enable = false;

  # Agent gateway does many concurrent LLM DNS lookups at cron boundaries.
  # Prefer AGH up first so early ticks don't race an empty cache/cold start.
  systemd.services.hermes-agent = {
    after = [ "adguardhome.service" ];
    wants = [ "adguardhome.service" ];
  };

  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}

# How to use the hybrid kid profile without it feeling clunky
#
# 1. Identify the PC
#    - Boot the PC, have it do some DNS queries (open a browser, etc.).
#    - In AdGuard UI look at Query log or the (runtime) Clients list.
#    - Note the IP (and hostname if it resolved).
#    - Give it a static DHCP lease (in router.nix staticLeases or your router)
#      so the IP is stable, then put the IP in ids above and rebuild.
#
# 2. The declarative profile is now active for that client:
#    - parental + safe search + filtering on
#    - uses the global filters you have in this file
#
# 3. Make the UI additive for extra blocks (the key to not being clunky)
#    - Go to Filters → Custom filtering rules
#    - Add rules scoped only to the toddler PC, e.g.:
#
#        ||tiktok.com^$client='toddler-pc'
#        ||instagram.com^$client='toddler-pc'
#        ||roblox.com^$client='toddler-pc'
#        ||^$client='toddler-pc'   # nuclear: block *everything* for it
#        @@||sesamestreet.org^$client='toddler-pc'   # then allow-list exceptions
#        @@||pbskids.org^$client='toddler-pc'
#
#    - Because we do not declare `user_rules` in Nix, these additions survive
#      `nixos-rebuild` / restarts.
#    - Use single quotes around the name if it has spaces or special chars:
#      $client='toddler-pc'
#
# 4. Per-client Blocked services (easiest for many categories)
#    - Settings → Client settings → edit "toddler-pc"
#    - Turn on "Use custom settings" / "Blocked services"
#    - Check the services you want blocked for just this device.
#    - This is stored outside the parts we declare, so UI wins here.
#
# 5. Optional: stricter allow-list mode for a 3-year-old
#    - One powerful pattern people use:
#        ||*^$client='toddler-pc'
#      then only @@ allow the sites/apps you explicitly want.
#    - Test thoroughly — some sites pull resources from CDNs that also need allows.
#
# 6. Tips
#    - The name "toddler-pc" (or whatever you choose) is what you use in $client=.
#    - Tags (we set "kids") let you do rules like $ctag=kids if you prefer groups.
#    - Global filters above still apply to the PC unless overridden.
#    - To add new kid-oriented subscription lists declaratively, just add
#      entries to the filters list (with a new unique id).
#      Example kid-focused list:
#        https://raw.githubusercontent.com/0xDarkMatter/aegis-blocklist/master/grades/standard.txt
#
# When you change the client definition in Nix it will be re-applied on next
# activation (Nix side wins for the fields we specify). Everything else in the
# UI stays yours.
