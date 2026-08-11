#!/usr/bin/env bash
# One-shot: remove leftover TorBox Media Center state after decommission.
# Run on the NAS as root after remote-test removes the container module.
set -euo pipefail

echo "==> stop unit if still present"
systemctl stop docker-torbox-media-center.service 2>/dev/null || true
systemctl disable docker-torbox-media-center.service 2>/dev/null || true

echo "==> remove container if still running"
docker rm -f torbox-media-center 2>/dev/null || true

echo "==> lazy-unmount FUSE leftovers under /var/lib/torbox"
if mountpoint -q /var/lib/torbox 2>/dev/null; then
  umount -l /var/lib/torbox || true
fi
# nested fuse mounts sometimes stack
while findmnt -n /var/lib/torbox >/dev/null 2>&1; do
  umount -l /var/lib/torbox || break
  sleep 0.5
done

echo "==> remove state dir (optional; frees ~TinyDB + empty tree)"
rm -rf /var/lib/torbox
# keep env file gone
rm -f /run/torbox-media-center.env

echo "==> optional: drop image"
docker image rm anonymoussystems/torbox-media-center:1.4.0 2>/dev/null || true
docker image rm anonymoussystems/torbox-media-center:latest 2>/dev/null || true

echo "==> done"
free -h | head -2
docker ps -a --format '{{.Names}}' | grep -i torbox || echo "(no torbox containers)"
