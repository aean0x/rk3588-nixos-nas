# Transmission torrent client with VPN killswitch and post-download extraction
{ config, pkgs, ... }:

let
  # Post-download script to extract compressed archives (rar, 7z, zip)
  # Runs as transmission user after torrent completion
  unpackScript = pkgs.writeShellScriptBin "transmission-unpack" ''
    set -euo pipefail

    LOG_FILE="/var/log/transmission-unpack.log"
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

    TORRENT_PATH="$TR_TORRENT_DIR/$TR_TORRENT_NAME"
    log "Processing: $TORRENT_PATH"

    if [[ ! -e "$TORRENT_PATH" ]]; then
      log "ERROR: Path does not exist"
      exit 1
    fi

    extract_archives() {
      local dir="$1"
      local found=0

      # RAR archives (skip .r00, .r01 etc - unrar handles them via main .rar)
      while IFS= read -r -d "" rar; do
        found=1
        log "Extracting RAR: $rar"
        ${pkgs.unrar}/bin/unrar x -o+ -y "$rar" "$(dirname "$rar")/" >> "$LOG_FILE" 2>&1 || log "WARN: unrar failed for $rar"
      done < <(find "$dir" -maxdepth 3 -name "*.rar" ! -name "*.part*.rar" -print0 2>/dev/null || true)

      # Also handle .part1.rar (multi-part naming)
      while IFS= read -r -d "" rar; do
        found=1
        log "Extracting multi-part RAR: $rar"
        ${pkgs.unrar}/bin/unrar x -o+ -y "$rar" "$(dirname "$rar")/" >> "$LOG_FILE" 2>&1 || log "WARN: unrar failed for $rar"
      done < <(find "$dir" -maxdepth 3 -name "*.part1.rar" -print0 2>/dev/null || true)

      # 7z archives
      while IFS= read -r -d "" archive; do
        found=1
        log "Extracting 7z: $archive"
        ${pkgs.p7zip}/bin/7z x -y -o"$(dirname "$archive")" "$archive" >> "$LOG_FILE" 2>&1 || log "WARN: 7z failed for $archive"
      done < <(find "$dir" -maxdepth 3 -name "*.7z" -print0 2>/dev/null || true)

      # ZIP archives
      while IFS= read -r -d "" archive; do
        found=1
        log "Extracting ZIP: $archive"
        ${pkgs.unzip}/bin/unzip -o -d "$(dirname "$archive")" "$archive" >> "$LOG_FILE" 2>&1 || log "WARN: unzip failed for $archive"
      done < <(find "$dir" -maxdepth 3 -name "*.zip" -print0 2>/dev/null || true)

      [[ $found -eq 0 ]] && log "No archives found"
    }

    if [[ -d "$TORRENT_PATH" ]]; then
      extract_archives "$TORRENT_PATH"
    elif [[ -f "$TORRENT_PATH" ]]; then
      case "$TORRENT_PATH" in
        *.rar) ${pkgs.unrar}/bin/unrar x -o+ -y "$TORRENT_PATH" "$TR_TORRENT_DIR/" >> "$LOG_FILE" 2>&1 ;;
        *.7z)  ${pkgs.p7zip}/bin/7z x -y -o"$TR_TORRENT_DIR" "$TORRENT_PATH" >> "$LOG_FILE" 2>&1 ;;
        *.zip) ${pkgs.unzip}/bin/unzip -o -d "$TR_TORRENT_DIR" "$TORRENT_PATH" >> "$LOG_FILE" 2>&1 ;;
        *)     log "Single file, not an archive" ;;
      esac
    fi

    log "Completed: $TR_TORRENT_NAME"
    exit 0
  '';
in
{
  nixarr.transmission = {
    enable = true;
    vpn.enable = true;
    openFirewall = false;

    extraSettings = {
      rpc-authentication-required = true;
      rpc-username = "transmission";

      cache-size-mb = 64;
      peer-limit-global = 500;
      peer-limit-per-torrent = 100;

      ratio-limit = 2.0;
      ratio-limit-enabled = true;

      script-torrent-done-enabled = true;
      script-torrent-done-filename = "${unpackScript}/bin/transmission-unpack";
    };

    credentialsFile = config.sops.secrets.services_transmission_credentials.path;
  };
}
