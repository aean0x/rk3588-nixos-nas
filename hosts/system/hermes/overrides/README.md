# overrides/ — explicit workarounds

Patches of upstream we intend to delete when the fix lands upstream.
Not first-party features (those stay in `integrations/`).

| Tree | What | Drop when |
|------|------|-----------|
| `package-fix.nix` | Silence-marker PYTHONPATH wrap + extras baked into `services.hermes-agent.package` + `hermesRuntimeEnv` | Upstream `_is_token` uses `_canonical_silence_candidates` |

Shared paths, PATH maps, and agent resource caps live in `../runtime.nix` (not here).
That file is SoT, not a workaround.
