#!/usr/bin/env bash
# One-shot: delete dead leaf keys from the live Hermes config.yaml.
#
# Why this exists: the NixOS activation step deep-MERGES the flake's
# settings into config.yaml and never deletes. A key an older seed wrote
# therefore survives every later deploy — renaming or retiring a model
# leaves its `compression.model_thresholds` entry behind forever. Nix
# cannot remove it (see AGENTS.md "No Nix one-shots for leftover state"),
# so the removal is a deliberate one-time edit; this script makes that
# edit verifiable instead of hand-typed.
#
# Leaf scalars only (a line `<indent><key>: <value>`). It refuses when the
# key matches zero or more than one line, or when the enclosing key is not
# the parent you named, so a wrong path cannot quietly delete something
# else. Nothing outside the named lines changes.
#
# Run on the NAS as root (or as the hermes user, who owns the file):
#   scp scripts/oneshot/prune-hermes-config-keys.sh rocknas:/tmp/
#   ssh rocknas 'sudo bash /tmp/prune-hermes-config-keys.sh compression.model_thresholds.deepseek-v4-flash'
#
# Dry run against a copy (no backup, no write):
#   CONFIG=/tmp/config.yaml bash scripts/oneshot/prune-hermes-config-keys.sh --dry-run a.b.leaf
set -euo pipefail

CONFIG="${CONFIG:-/var/lib/hermes/.hermes/config.yaml}"
DRY=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY=1
  shift
fi

if [[ $# -lt 1 ]]; then
  echo "usage: $0 [--dry-run] <dotted.key.path> [more...]" >&2
  exit 2
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: no such config: $CONFIG" >&2
  exit 1
fi
if [[ "$DRY" -eq 0 && ! -w "$CONFIG" ]]; then
  echo "ERROR: not writable: $CONFIG — run as root or as the file owner" >&2
  exit 1
fi

work="$(mktemp -p "$(dirname "$CONFIG")")"
trap 'rm -f "$work"' EXIT
cp -p "$CONFIG" "$work"

# Nearest preceding line with smaller indentation must be the named parent.
parent_of() {
  awk -v hit="$1" -v want="$2" '
    { match($0, /^ */); ind[NR] = RLENGTH; line[NR] = $0 }
    END {
      i = ind[hit]
      for (n = hit - 1; n >= 1; n--) {
        if (ind[n] < i) {
          key = line[n]
          sub(/^[ ]*/, "", key)
          sub(/:.*/, "", key)
          print (key == want ? "ok" : "bad:" key)
          exit
        }
      }
      print "none"
    }' "$work"
}

for path in "$@"; do
  parent="${path%.*}"
  leaf="${path##*.}"
  parent_leaf="${parent##*.}"
  if [[ "$parent" == "$path" || -z "$leaf" || -z "$parent_leaf" ]]; then
    echo "ERROR: '$path' is not a dotted leaf path" >&2
    exit 2
  fi

  pattern="^[[:space:]]*${leaf//./\\.}:[[:space:]]"
  mapfile -t hits < <(grep -nE "$pattern" "$work" | cut -d: -f1 || true)
  if [[ "${#hits[@]}" -ne 1 ]]; then
    echo "ERROR: '$path' matches ${#hits[@]} line(s) — need exactly 1" >&2
    grep -nE "$pattern" "$work" >&2 || true
    exit 1
  fi

  verdict="$(parent_of "${hits[0]}" "$parent_leaf")"
  if [[ "$verdict" != "ok" ]]; then
    echo "ERROR: '$path' — the enclosing key of that line is not '${parent_leaf}:' (found '${verdict#bad:}')" >&2
    exit 1
  fi

  echo "==> removing $path"
  echo "    - $(sed -n "${hits[0]}p" "$work")"
  sed -i "${hits[0]}d" "$work"
done

echo
echo "==> diff (the only changes)"
if ! diff -u "$CONFIG" "$work"; then
  :
fi

# The write must be atomic and must keep the original mode: a truncated or
# reformatted config.yaml breaks the live gateway.
if [[ "$DRY" -eq 1 ]]; then
  echo
  echo "==> dry run: $CONFIG left untouched"
  exit 0
fi

mode="$(stat -c '%a' "$CONFIG")"
backup="$CONFIG.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$CONFIG" "$backup"
chmod "$mode" "$work"
mv -f "$work" "$CONFIG"
trap - EXIT

echo
echo "==> wrote $CONFIG (mode $mode)"
echo "==> backup: $backup"
echo "==> restore: cp -p '$backup' '$CONFIG'"
echo
echo "No gateway restart is needed when the removed keys were dead (a model id"
echo "nothing runs any more). Restart hermes-agent if you pruned a live key."
