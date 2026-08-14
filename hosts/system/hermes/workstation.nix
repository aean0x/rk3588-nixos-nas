# Hermes → sole coding workstation (Grok agent user over SSH).
#
# PATH wrappers + declarative skill "workstation". Not MCP tools.
# Private key stays under /run/secrets only — never in hermes HOME. Wrappers
# pass -i to OpenSSH; skill does not document the secret path.
{
  lib,
  pkgs,
  ...
}: let
  workstationHost = "192.168.1.71";
  workstationUser = "agent";
  secretPath = "/run/secrets/nix_pc_agent_ssh_key";

  # Config used only by wrappers (not a general-purpose ~/.ssh/config the model
  # is encouraged to inspect). IdentityFile points at the secret mount.
  sshConfig = pkgs.writeText "hermes-workstation-ssh-config" ''
    Host workstation
      HostName ${workstationHost}
      User ${workstationUser}
      IdentityFile ${secretPath}
      IdentitiesOnly yes
      StrictHostKeyChecking accept-new
      UserKnownHostsFile /var/lib/hermes/home/.ssh/known_hosts
      BatchMode yes
      ConnectTimeout 10
  '';

  # Single internal hop: always injects config (and thus the key path).
  sshWorkstation = pkgs.writeShellScript "ssh-workstation" ''
    set -euo pipefail
    export HOME="''${HOME:-/home/hermes}"
    CFG=${sshConfig}
    KEY=${secretPath}
    if [[ ! -r "$KEY" ]]; then
      echo "ssh-workstation: identity secret missing or unreadable ($KEY)" >&2
      echo "Fix: sops secret nix_pc_agent_ssh_key + container mount." >&2
      exit 1
    fi
    exec ${pkgs.openssh}/bin/ssh -F "$CFG" workstation "$@"
  '';

  checkoutWorkstation = pkgs.writeShellScript "checkout-workstation" ''
    exec ${sshWorkstation} workstation-checkout on
  '';

  releaseWorkstation = pkgs.writeShellScript "release-workstation" ''
    exec ${sshWorkstation} workstation-checkout off
  '';

  statusWorkstation = pkgs.writeShellScript "workstation-status" ''
    exec ${sshWorkstation} workstation-checkout status
  '';
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/hermes/home 0755 hermes hermes -"
    "d /var/lib/hermes/home/.ssh 0700 hermes hermes -"
    "d /var/lib/hermes/home/.local/bin 0755 hermes hermes -"
  ];

  system.activationScripts.hermes-workstation = lib.stringAfter ["users" "setupSecrets"] ''
    install -d -m 0700 -o hermes -g hermes /var/lib/hermes/home/.ssh
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/home/.local/bin

    # Wrappers only — no private key file under HOME.
    install -m 0755 -o hermes -g hermes ${sshWorkstation} /var/lib/hermes/home/.local/bin/ssh-workstation
    install -m 0755 -o hermes -g hermes ${checkoutWorkstation} /var/lib/hermes/home/.local/bin/checkout-workstation
    install -m 0755 -o hermes -g hermes ${releaseWorkstation} /var/lib/hermes/home/.local/bin/release-workstation
    install -m 0755 -o hermes -g hermes ${statusWorkstation} /var/lib/hermes/home/.local/bin/workstation-status

    # Known hosts dir (created on first connect); keep empty config-free.
    touch /var/lib/hermes/home/.ssh/known_hosts
    chown hermes:hermes /var/lib/hermes/home/.ssh/known_hosts
    chmod 0644 /var/lib/hermes/home/.ssh/known_hosts

    # Skill for discovery (/workstation, skills_list).
    install -d -m 0755 -o hermes -g hermes /var/lib/hermes/.hermes/skills/devops/workstation
    install -m 0644 -o hermes -g hermes ${./skills/workstation/SKILL.md} \
      /var/lib/hermes/.hermes/skills/devops/workstation/SKILL.md

    install -d -m 2770 -o hermes -g hermes /var/lib/hermes/workspace
    # Hermes-owned after seed; wrappers + skill stay force-managed above.
    if [ ! -f /var/lib/hermes/workspace/WORKSTATION.md ]; then
      cat > /var/lib/hermes/workspace/WORKSTATION.md <<'EOF'
# Coding workstation (remote Grok)

Host must be **powered on**. Use wrappers only — do not dig for SSH keys.

| Command | Effect |
|---------|--------|
| `checkout-workstation` | Keep host awake (sleep:idle latch) |
| `release-workstation` | Allow normal idle/sleep |
| `workstation-status` | `checked-out` or `released` |
| `ssh-workstation …` | Run command as remote `agent` |

```bash
checkout-workstation
ssh-workstation 'bash -lc "grok --always-approve -p \"…\""'
release-workstation
```
EOF
      chown hermes:hermes /var/lib/hermes/workspace/WORKSTATION.md
      chmod 0640 /var/lib/hermes/workspace/WORKSTATION.md
    fi
  '';

  # Secret readable by hermes only via this mount (for OpenSSH -i inside wrappers).
  # Not copied into HOME. Model can still `cat` the mount if it tries — wrappers
  # + skill discourage that; true air-gap would need a privileged ssh proxy.
  services.hermes-agent.container.extraVolumes = [
    "${secretPath}:${secretPath}:ro"
  ];

  environment.systemPackages = [pkgs.openssh];
}
