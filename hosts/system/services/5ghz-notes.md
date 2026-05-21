# 5 GHz Dual-Band Notes (WCN7850 / NixOS hostapd)

## Status
Stowed — working approach identified, blocked by a NixOS module evaluation issue. Resume when time allows.

## What works
- WCN7850 (ath12k_wifi7_pci) exposes a single `phy0` with DBDC capability (`#channels <= 2`), meaning 2.4 GHz + 5 GHz can run simultaneously.
- Regdom passive scan trick already in place (`hostapd-regdom` service) — US country code unlocks all 5 GHz channels at full power.
- Available 5 GHz channels (post-regdom):
  - UNII-1 ch36–48: 24 dBm, no DFS
  - UNII-3 ch149–173: 30 dBm, no DFS  ← preferred (more power, less residential congestion)
- Chosen target: **ch149, 80 MHz width, centre ch155 (5775 MHz)**

## Implementation approach
1. `hostapd-regdom` creates the 5 GHz VIF before hostapd starts:
   ```bash
   iw phy phy0 interface add wlP2p33s0_5g type managed
   ```
2. `services.hostapd.radios` gains a second entry for `wlP2p33s0_5g`:
   ```nix
   radios."wlP2p33s0_5g" = {
     band = "5g";
     channel = 149;
     inherit countryCode;
     wifi4.enable = true;
     wifi5 = {
       enable = true;
       operatingChannelWidth = "80";  # sets vht_oper_chwidth=1
     };
     settings = {
       ieee80211d = true;
       ieee80211h = true;
       uapsd_advertisement_enabled = 0;
       vht_oper_centr_freq_seg0_idx = 155;
     };
     networks."wlP2p33s0_5g" = { /* same ssid + auth as 2.4 GHz */ };
   };
   ```
3. `hostapd-bridge` updated to join both interfaces to `br0`.

## The freeform merge conflict (root cause of build failure)
`services.hostapd.radios.*.settings` uses `freeformType = types.attrsOf atom`.
When `wifi5.enable = true`, the NixOS hostapd module automatically injects
`vht_oper_chwidth = radioCfg.wifi5.operatingChannelWidth` into `config.settings`.
If `vht_oper_chwidth` is also set explicitly in the user `settings` attrset,
the module system produces a conflicting definition whose merged value is not
a plain int/bool/string — `generators.toKeyValue` then throws at serialisation
(`pkgs.writeText` assertion: `isConvertibleWithToString`).

**Fix**: never set `vht_oper_chwidth` in `settings`. Use the structured option
`wifi5.operatingChannelWidth = "80"` instead. The module will emit the correct
`vht_oper_chwidth=1` line itself. Only `vht_oper_centr_freq_seg0_idx` needs to
be in `settings` (no structured equivalent exists for it).

The approach above already incorporates this fix and should build cleanly.
