# Sonarr + Radarr + RDT-Client (TorBox)

## What runs

| Service | Port | URL |
|---------|------|-----|
| **Sonarr** | 8989 (loopback) | `https://sonarr.<domain>` |
| **Radarr** | 7878 (loopback) | `https://radarr.<domain>` |
| **RDT-Client** | 6500 (loopback) | `https://rdt.<domain>` |

RDT-Client talks to **TorBox** (`torbox_api_key` in sops) and pretends to be **qBittorrent** so Sonarr/Radarr can send magnets/torrents.

## Paths

| Host path | Role |
|-----------|------|
| `/media/Videos/Movies` | Movie library (bind-mounted as `…/library/movies`) |
| `/media/Videos/Shows` | TV library (bind-mounted as `…/library/shows`) |
| `/media/Videos/downloads` | RDT download cache (Sonarr/Radarr import from here) |
| `/var/lib/nixarr` | Sonarr/Radarr state |
| `/var/lib/rdtclient` | RDT-Client DB |

Nixarr always uses `${mediaDir}/library/{movies,shows}`. We **bind-mount** your existing `Movies` / `Shows` folders there so both layouts stay in sync.

## Secrets (sops)

```yaml
torbox_api_key: "…"
rdtclient_username: "admin"
rdtclient_password: "…"
```

On boot, `rdtclient-bootstrap` creates the RDT admin user (if needed), sets provider=TorBox + API key, and maps download paths.

## How they link

1. **RDT-Client** ← TorBox API  
2. **Sonarr/Radarr** ← download client **RDT-Client** (qBittorrent protocol, categories `sonarr` / `radarr`) via nixarr `settings-sync`  
3. Completed files land under `/media/Videos/downloads/{sonarr,radarr}/…` and *arr import into the library folders  

## First-time UI checks

If something did not auto-wire:

### RDT-Client (`:6500`)

1. Log in with `rdtclient_username` / `rdtclient_password`.  
2. **Settings → Provider** = TorBox, paste API key if empty.  
3. **Download path** = `/data/downloads`  
4. **Mapped path** = `/media/Videos/downloads`  
5. **Categories** = `sonarr,radarr`

### Sonarr

1. **Settings → Media Management → Root Folders** → add  
   `/media/Videos/library/shows`  
   (same files as `/media/Videos/Shows`)  
2. **Settings → Download Clients** → qBittorrent:  
   - Host `127.0.0.1`, Port `6500`  
   - User/pass = RDT credentials  
   - Category `sonarr`  
3. Indexers: add via Prowlarr later, or **Settings → Indexers** manually.

### Radarr

Same as Sonarr but root folder `/media/Videos/library/movies` and category `radarr`.

## Modules

| File | Role |
|------|------|
| `hosts/system/services/arr-suite.nix` | Nixarr Sonarr + Radarr, library binds, root-folder oneshot |
| `hosts/system/containers/rdtclient.nix` | RDT-Client OCI container, TorBox bootstrap, Caddy `rdt.*` |

Flake input: `nixarr` → `github:nix-media-server/nixarr`.
