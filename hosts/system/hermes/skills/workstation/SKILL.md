---
name: workstation
description: "Check out / release the coding workstation and run Grok Build there over SSH."
version: 1.1.0
platforms: [linux]
metadata:
  hermes:
    tags: [workstation, grok, ssh, checkout, coding-agent, desktop]
    category: devops
    requires_toolsets: [terminal]
    related_skills: [grok]
---

# Coding workstation

The user's **desktop coding machine** (only one). Remote account `agent` runs Grok Build.  
Invoke via the **`terminal`** tool — these are PATH wrappers, not MCP tools.

## When to use

- “Check out the workstation / keep the PC awake / latch for remote work”
- “Release the workstation when done”
- Grok Build / coding agent work on the desktop / workstation
- Status of the checkout latch

## Commands (use only these)

| Command | Effect |
|---------|--------|
| `checkout-workstation` | Latch: block idle sleep on the workstation |
| `release-workstation` | Unlatch: normal sleep policy |
| `workstation-status` | `checked-out` or `released` |
| `ssh-workstation <cmd…>` | SSH as remote agent and run a command |

Do **not** search for SSH private keys, `IdentityFile`, or `/run/secrets`. Wrappers inject credentials; treat keys as out of bounds.

## Procedure

```bash
# 1. Before remote work (e.g. morning)
checkout-workstation
workstation-status    # checked-out

# 2. Work
ssh-workstation true
ssh-workstation 'hostname; whoami; command -v grok'
ssh-workstation 'bash -lc "cd <project> && grok --always-approve -p \"…\""'

# 3. Done
release-workstation
workstation-status    # released
```

## Pitfalls

- Host must already be **powered on** (no Wake-on-LAN).
- Prefer **one checkout**, many SSH/Grok calls, **one release**.
- Auth/secret failures: report wrapper error text; do not try to open key files.
- Slash: `/workstation`

## Verification

```bash
checkout-workstation && workstation-status
ssh-workstation 'echo OK; whoami'
release-workstation && workstation-status
```
