# hermes-context-manager overlay

Installed over upstream  (and config.py/config.yaml)
by .

## Why
Upstream HMC only measured at turn start and could not rewrite tool results.
This overlay adds:

1.  — return a **string** (Hermes ignores non-string returns)
2.  — measure every mid-loop call via 
3. Absolute budget 
4. Correct session state via  and SessionState fields
   (, , ,
   , , )
5. Mutate  (API payload) and  (live)

## Bugs fixed 2026-07-31 follow-up
-  AttributeError on every under-budget 
  (log: "HMC pre_api_request failed")
- Handler looked for  but Hermes passes 
- Transform must return a plain string, not 

After deploy: restart hermes gateway so hooks reload.
