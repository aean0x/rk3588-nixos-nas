# Robinhood Crypto MCP (read-only)

Hermes exposes **read-only** Robinhood **crypto** tools via MCP `robinhood-crypto`.

- **API:** crypto Trading API only (`trading.robinhood.com`) — not equities/options.
- **Server:** `npx -y robinhood-mcp` (data server). Quotes, holdings, account, order history, cost basis.
- **Not enabled:** `robinhood-mcp-trading`, daemon, or `ROBINHOOD_CRYPTO_ENABLE_TRADING=1`.

## Operator setup

1. `npx robinhood-keygen` → Ed25519 seed + public key  
2. Register public key at https://robinhood.com/account/crypto (**classic** web UI)  
3. Sops: `robinhood_crypto_api_key` + `robinhood_crypto_private_key`  
4. `settings.enableRobinhoodCryptoSecrets = true`  
5. Deploy + `systemctl restart hermes-agent`

Full steps: `hosts/system/hermes/BOOTSTRAP.md` §3.
