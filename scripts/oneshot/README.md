# One-shot / archive scripts

Drop **general-purpose, one-time, or rarely re-run** scripts here for archival and future reference.

- Not wired into `./deploy` or NixOS modules.
- Prefer a short header comment: what, when, how to run, host vs NAS.
- Keep deploy/lifecycle tools in `scripts/` root (`common.sh`, `install.sh`, …).

Examples:

- `ersatztv-seed-music.sh` — seed MTV flood channels in ErsatzTV SQLite.
- `prune-hermes-config-keys.sh` — delete dead leaf keys (e.g. a retired
  model id's `compression.model_thresholds` entry) from the live
  `config.yaml`. Activation only deep-merges, so a key an older seed wrote
  survives every later deploy; removing it is a deliberate one-time edit.
