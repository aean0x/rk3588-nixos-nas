# overrides/ — explicit workarounds

Patches of upstream we intend to delete when the fix lands upstream.
Not first-party features (those stay in `integrations/`).

| Tree | What | Drop when |
|------|------|-----------|
| `package-fix.nix` | leftover — silence wrap + extras bake moved to hermes-pnp composer | delete after cutover is live |

Shared paths, PATH maps, and agent resource caps live in `../runtime.nix` (not here).
That file is SoT, not a workaround.
