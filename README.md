# x420

Single VPS, single port proxy installer.

This repository intentionally keeps only one deployment path:

- Xray VLESS Vision on `443/tcp`
- TLS 1.3 with normal HTTPS fallback
- Caddy fallback on `127.0.0.1:8080`
- Linux `BBR + fq`
- No mux, no OpenVPN, no WireGuard-over-TCP, no CAKE limiter, no adaptive tuner

The goal is a clean, low-variable baseline for Shadowrocket on one VPS.

## Install

Run as root on a Debian/Ubuntu VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh) \
  --domain example.com
```

Optional fixed UUID:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh) \
  --domain example.com \
  --uuid 00000000-0000-0000-0000-000000000000
```

If you already have certificate files:

```bash
bash install.sh \
  --domain example.com \
  --cert-file /path/fullchain.pem \
  --key-file /path/private.key
```

## Output

The installer prints a Shadowrocket `vless://` link and saves it on the server:

```text
/root/<domain>-shadowrocket-vless-443.txt
```

## Checks

```bash
systemctl status xray --no-pager
systemctl status caddy --no-pager
ss -lntp | grep -E ':(22|443|8443|8080) '
curl -kI https://example.com/
```

Expected public proxy port:

```text
443/tcp only
```
