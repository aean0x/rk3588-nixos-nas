# Hermes Agent — Architecture Notes

## Deployment Model

Container mode: the `hermes-agent` NixOS module manages a persistent Docker container
(Ubuntu 24.04). The Nix-built binary is bind-mounted read-only from `/nix/store`. The
container provides a mutable Ubuntu userland where the agent can self-install packages via
`apt`/`pip`/`npm` that persist across restarts.

The systemd service (`hermes-agent`) manages the container lifecycle. The gateway process
runs inside the container and connects to messaging platforms (Telegram etc.).

## Path Mapping (host → container)

| Host | Container | Mode |
|------|-----------|------|
| `/nix/store` | `/nix/store` | ro |
| `/var/lib/hermes` | `/data` | rw |
| `/var/lib/hermes/home` | `/home/hermes` | rw |
| `/var/lib/hermes/workspace` | `/data/workspace` | (under /data rw) |

`HERMES_HOME` inside the container resolves to `/data/.hermes` (= `/var/lib/hermes/.hermes`
on host).

## Container Identity and Recreation

The container is only recreated when its **identity hash** changes. The hash covers the
schema version, `container.image`, `container.extraVolumes`, `container.extraOptions`, and
the entrypoint script. Code changes (new hermes version) do **not** trigger recreation —
`nixos-rebuild switch` only updates the `/data/current-package` symlink, picked up on the
next restart.

When the container IS recreated (image change, new volumes/options): all `apt`/`pip`/`npm`
installs in the writable layer are lost. State in `/data` and `/home/hermes` (bind mounts)
is preserved.

## SOUL.md — Critical Gotcha

The `documents` option installs files into `workingDirectory` (= `/var/lib/hermes/workspace`).
**SOUL.md placed in `documents` does NOT set the primary identity.** The primary identity
file is `${stateDir}/.hermes/SOUL.md`.

We install SOUL.md via an activation script reading from a `pkgs.writeText` Nix store path,
so it is always in sync after `nixos-rebuild switch` without depending on the workspace copy.

```
workspace/soul.md  →  pkgs.writeText (Nix store)  →  activation script  →  /var/lib/hermes/.hermes/SOUL.md
```

The activation script runs after the module's `hermes-agent-setup` step (which creates
the `hermes` user and `.hermes/` directory) and unconditionally overwrites the file.
Agent-initiated changes to SOUL.md will be overwritten on the next rebuild — this is
intentional; identity is owned by Nix.

## Secrets

`environmentFiles = [ "/run/hermes.env" ]` is merged into `${stateDir}/.hermes/.env` at
activation. Hermes re-reads `.env` on every startup, so secret rotation only needs
`systemctl restart hermes-agent` — no container recreation.

## CLI Routing

When `container.enable = true` and `addToSystemPackages = true`, all `hermes` commands on
the host transparently exec into the container. Users in `hostUsers` get a `~/.hermes`
symlink to the service state dir so interactive sessions share state (sessions, skills,
cron) with the gateway. If the container is not running, the CLI retries for 5s then fails
with a clear error.

## Managed Mode Guards

The following CLI commands are blocked inside managed mode:

- `hermes setup`, `hermes config edit`, `hermes config set`
- `hermes gateway install`, `hermes gateway uninstall`

Detection: `HERMES_MANAGED=true` env var (set by the service) and a `.managed` marker file
in `HERMES_HOME`. Both must be circumvented to escape managed mode — don't.

## OneDrive Sync

`onedrive.nix` defines a host-side systemd service + timer running as the `hermes` user.
It syncs `onedrive:Shared` and `onedrive:Documents` into `/var/lib/hermes/workspace/onedrive/`,
which the container sees at `/data/workspace/onedrive/`. Timer: 15m with 2m randomized delay.

The rclone config is read from sops secret `onedrive_rclone_config`, copied to `/tmp` at
runtime with `chmod 600`, and deleted via `trap`. `HOME=${stateDir}` is set so rclone can
write its cache without needing `/root`.

## Maintenance Commands

```bash
# Service + logs
systemctl status hermes-agent
journalctl -u hermes-agent -f
docker logs -f hermes-agent

# Container inspection
docker ps -a --filter name=hermes-agent
docker exec -it hermes-agent bash

# Verify secrets loaded
docker exec hermes-agent cat /data/.hermes/.env

# Verify SOUL.md (primary identity)
docker exec hermes-agent cat /data/.hermes/SOUL.md

# Force container recreation (resets writable layer, preserves /data state)
systemctl stop hermes-agent
docker rm -f hermes-agent
rm /var/lib/hermes/.container-identity
systemctl start hermes-agent
```

## GC Root

The module's `preStart` creates `/var/lib/hermes/.gc-root` pointing at the current hermes
package, protecting it from `nix-collect-garbage`. Recreated automatically on service start.

## Gateway & Telegram

`TELEGRAM_BOT_TOKEN` in the env file activates the Telegram gateway automatically — no
`hermes gateway setup` or `hermes gateway install` needed (and those are blocked in managed
mode anyway). `TELEGRAM_ALLOWED_USERS` is mapped to the same `telegram_admin_id` sops secret
so the admin Telegram ID is pre-authorized on first boot; without it the gateway defaults to
deny-all and requires DM pairing before anyone (including the owner) can use the bot.

To add more authorized users later, run `hermes pairing approve telegram <code>` from the
CLI (the user DMs the bot and sends the pairing code they receive).

## Lessons Learned

- **SOUL.md in `documents` is a no-op for identity** — must install directly to
  `.hermes/SOUL.md`. The docs call this out explicitly but it's easy to miss.
- **Activation script must not depend on the workspace copy** — use `pkgs.writeText` for a
  stable Nix store path that exists independently of document installation order.
- **Do not `|| true` activation script failures** — they mask misconfigured ownership or
  missing parent directories. Let it fail loudly.
- **Container recreation wipes apt/pip installs** — if the agent relies on specific packages,
  bake them into a custom image (`container.image = "my-registry/hermes-base:latest"`) or
  document them in SOUL.md for re-installation.
- **`nixos-rebuild switch` does not restart the container** — only the symlink is updated.
  `systemctl restart hermes-agent` is needed to pick up a new binary.
- **`streaming = "block"` is wrong** — must be `streaming.mode = "block"` (nested attr, not a
  bare string). This bit openclaw config and would hit hermes config the same way.
- **`messaging` not `telegram` for the gateway extra** — `telegram` is not a valid
  optional-dependency group. The correct name is `messaging` (python-telegram-bot,
  discord.py, slack-bolt). Also: `messaging` was removed from `all` on 2026-05-12 and
  must be listed in `extraDependencyGroups` explicitly.
- **`.env` is 0600 at runtime** — the hermes process rewrites it to 0600 after activation
  sets 0640. The fix is `setfacl -dm u:<adminUser>:r <stateDir>/.hermes` (default ACL on
  the directory), which new files inherit even after atomic rename rewrites. Adding
  adminUser to the hermes group alone is insufficient.
- **Dashboard must run as `hermes` user, not adminUser** — adminUser cannot read `.env`
  (0600 hermes:hermes). The hermes service user owns the file. Add hermes to docker group
  so the dashboard's CLI routing can `docker exec` into the container.
- **`TELEGRAM_ALLOWED_USERS` not `TELEGRAM_ADMIN_ID`** — hermes uses `TELEGRAM_ALLOWED_USERS`
  for gateway access control; `TELEGRAM_ADMIN_ID` is an OpenClaw artifact. Both are in
  hermesSecrets mapping to the same sops key.
- **`timezone` must be set explicitly** — hermes defaults to server-local time (UTC), not the
  system timezone. Set `timezone = "Europe/Berlin"` in settings for correct cron schedules.
- **`security.redact_secrets`** — defaults to false; set to true for gateway deployments so
  API key patterns are stripped before appearing in Telegram messages.
