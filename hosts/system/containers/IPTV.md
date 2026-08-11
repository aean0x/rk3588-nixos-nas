# ErsatzTV IPTV (local media)

LAN “live TV” from files on the NAS. Google TV / Bravia opens an M3U playlist.

## Stack

| Piece | Role | Host path / port |
|-------|------|------------------|
| **Local media** | Music videos / movies on the data pool | `/media/Videos` (SMB/NFS: `Media`) |
| **ErsatzTV** | Scans libraries, builds channels, streams + EPG | `:8409`, config `/var/lib/ersatztv` |
| **Caddy** | LAN HTTPS UI | `https://tv.aean.io` |

Module: `ersatztv.nix` (imported from `containers.nix`).  
TorBox Media Center was removed (FUSE index idled ~1.5 GiB); drop files onto `/media` from a PC instead.

```
/media/Videos/{Music Videos,Movies,Shows}
        │ bind :ro
        ▼
  ersatztv  :8409  →  M3U + XMLTV + HLS/TS  →  Bravia / TiviMate / VLC
```

## Demo channels (music videos)

Seeded by `scripts/oneshot/ersatztv-seed-music.sh` (re-runnable):

| # | Channel | Playback |
|---|---------|----------|
| 10 | MTV Shuffle | Shuffle flood |
| 11 | MTV Chronological | Chronological flood |

Smart collection: **All Music Videos** (`type:music_video`).  
Library path in ETV: `/media/library/Music Videos` ← host `/media/Videos/Music Videos`.

## FFmpeg / load

Mainline kernel has **no usable H.264 Rkmpp** for ETV. Profile is software:

- **480p** · `libx264` **ultrafast** · **2 threads** · ~800 kbit/s  
- UI: Settings → FFmpeg Profiles → `480p x264 ultrafast (lean)`

## One-time seed / ops

```bash
# after Videos exist on the NAS
scp scripts/oneshot/ersatztv-seed-music.sh rocknas:/tmp/
ssh rocknas 'sudo bash /tmp/ersatztv-seed-music.sh'
```

```bash
./deploy logs ersatztv
./deploy journal docker-ersatztv
```

## Clients

- M3U: `http://192.168.1.200:8409/iptv/channels.m3u`
- XMLTV: `http://192.168.1.200:8409/iptv/xmltv.xml`
- UI: `http://192.168.1.200:8409` or `https://tv.aean.io`

## File drop (whole drive)

Guest SMB/NFS shares the **entire** data pool:

- `smb://rocknas.local/Media` → `/media` (Videos/, Files/, …)
- NFS: `rocknas.local:/media`

See `services/filesharing.nix`.

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Empty library | Files under `/media/Videos/...`; rescan Music Videos library in ETV |
| Buffers every ~10s | Transcode too slow — stay on 480p lean profile; avoid concurrent heavy jobs |
| TV cannot open M3U | Same LAN; use `http://192.168.1.200:8409/...` |
