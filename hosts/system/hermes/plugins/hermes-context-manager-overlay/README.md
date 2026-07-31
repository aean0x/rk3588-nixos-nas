# HMC overlay (Hermes Context Manager)

Copied over upstream after `context-manager.nix` installs the pinned HMC tree.

## Fixes (2026-07-31)
- `transform_tool_result` — actually truncates tool output before history append
- `pre_api_request` — uses Hermes `approx_input_tokens`; prunes live tool content
- `compress.max_context_tokens: 120000` — absolute budget so large windows compress before 200k+
- Tighter truncation defaults (40 lines)

Root cause of prior 0 savings / ~1% context: `post_tool_call` is observational only.
