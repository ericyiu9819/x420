# Security Notes

This repository should contain the deployment script only.

Do not commit:

- generated `client/*.json`
- generated `server/*.json`
- `vless://` import links
- REALITY private keys
- UUIDs used by real production nodes
- VPS passwords
- deployment records that identify active infrastructure

Generated node files should stay local or be stored in a private secret manager.
