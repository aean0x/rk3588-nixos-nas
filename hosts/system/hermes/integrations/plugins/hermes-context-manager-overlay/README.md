# hermes-context-manager overlay

Installed over upstream hermes_context_manager/plugin.py by context-manager.nix.

## Why
Adds transform_tool_result + pre_api_request measurement/prune with absolute 120k budget.

## Bugs fixed 2026-07-31 follow-up
- self.state AttributeError on every under-budget pre_api_request
- Handler looked for messages= but Hermes passes request_messages=
- Transform must return a plain string

After deploy: restart hermes gateway so hooks reload.
