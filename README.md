# x420

C-VLESS FastRelay is a single-line VLESS/TLS/TCP 443 deployment for Debian/Ubuntu VPS nodes.

The goal is practical TCP performance on weak or cheap routes: keep the public entry compatible with Shadowrocket, make the traffic look like ordinary TLS, and keep the backend proxy path as small as possible.

## Traffic Path

```text
Shadowrocket
-> VLESS + TLS over TCP/443
-> HAProxy TLS camouflage entry
-> 127.0.0.1:18080
-> C VLESS FastRelay
-> target TCP service
```

## What It Installs

- A C VLESS TCP relay using epoll accept plus pthread connection handlers
- Linux `splice()` relay after the VLESS handshake
- HAProxy TLS entry on public TCP/443
- A small decoy HTTPS page for browser or HTTP probes
- BBR/fq and TCP buffer tuning
- systemd services:
  - `c-vless-fastrelay.service`
  - `c-vless-fastrelay-tls.service`

## What It Does Not Do

- No UDP
- No QUIC
- No WireGuard or TUN mode
- No Reality/Vision/Mux
- No panel
- No multi-line load balancing

This is intentionally a TCP-only path for browsing, ChatGPT, image upload, file upload, and other TCP workloads.

## Quick Install

Run as root on a Debian/Ubuntu VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/onekey.sh)
```

The one-key entry uses these defaults:

```text
port:   443
tls:    enabled
sni:    www.apple.com
remark: C-VLESS-TLS
host:   auto-detected on the VPS
uuid:   auto-generated on the VPS
```

To pin the public IP or domain:

```bash
X420_HOST=YOUR_SERVER_IP_OR_DOMAIN bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/onekey.sh)
```

Advanced install:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh) install \
  --host YOUR_SERVER_IP_OR_DOMAIN \
  --port 443 \
  --tls \
  --sni www.apple.com \
  --remark C-VLESS-TLS
```

The installer prints a Shadowrocket `vless://` link and also saves client files on the server:

```text
/root/c-vless-fastrelay/shadowrocket-vless.uri
/root/c-vless-fastrelay/xray-client.json
```

## Existing Xray On 443

If another proxy already owns TCP/443, stop it before installing:

```bash
systemctl disable --now xray 2>/dev/null || true
systemctl disable --now v2ray 2>/dev/null || true
systemctl disable --now sing-box 2>/dev/null || true
```

Then run the installer.

## Real Certificate Mode

The default `--tls` mode generates a self-signed certificate. That is convenient for testing, but Shadowrocket must allow insecure certificates.

For stronger camouflage, use your own domain and HAProxy PEM file:

```bash
bash install.sh install \
  --host your.domain.com \
  --port 443 \
  --tls \
  --sni your.domain.com \
  --cert-pem /path/to/fullchain-plus-private-key.pem \
  --strict-tls
```

The PEM file must contain both the certificate chain and the private key.

## Commands

```bash
sudo ./install.sh install --host YOUR_SERVER_IP --port 443 --tls --sni www.apple.com
sudo ./install.sh validate
sudo ./install.sh status
sudo ./install.sh print-client
sudo ./install.sh restart
sudo ./install.sh uninstall
```

## Validation

Public TLS and decoy page:

```bash
curl -k --resolve www.apple.com:443:YOUR_SERVER_IP https://www.apple.com/ -i
```

Expected:

```text
HTTP/1.1 200 OK
Server: nginx
```

Server state:

```bash
ss -ltnup | egrep ':(443|18080)\b'
systemctl is-active c-vless-fastrelay c-vless-fastrelay-tls
```

Expected:

```text
0.0.0.0:443        haproxy
127.0.0.1:18080    c-vless-fastrelay
active
active
```

## Rollback

Remove the C-VLESS services:

```bash
sudo ./install.sh uninstall
```

If you previously used Xray and want it back:

```bash
systemctl enable --now xray
```

## Security Notes

Do not commit live node links, root passwords, private keys, or generated UUIDs into this repository.

Self-signed TLS only disguises the transport shape. A real domain certificate is stronger.

## Tested Shape

The deployment has been validated on Debian 12 VPS nodes with:

- external TLS handshake on TCP/443
- decoy HTTPS page returning 200
- VLESS client exit IP matching the VPS public IP
- 1MiB upload returning HTTP 200
