# x420

Single-VPS Shadowrocket VLESS TCP+TLS installer.

This repository contains one deployable script:

```text
shadowrocket_vless_tcp_tls_install.sh
```

It installs Xray-core on a Debian/Ubuntu VPS, creates a VLESS over TCP+TLS inbound, applies TCP performance tuning, enables a lightweight adaptive health optimizer, and prints a Shadowrocket-compatible `vless://` line.

## Features

- Xray-core installation
- VLESS + TCP + TLS on a single VPS
- Shadowrocket import link output
- Let's Encrypt certificate mode for domain-based deployments
- Self-signed certificate mode for IP-only deployments
- Linux TCP baseline tuning
- BBR support when available
- Adaptive high-connection TCP profile
- systemd service and timer setup
- Status, show, optimizer-run, and uninstall commands

## Quick Start With A Domain

Point your domain to the VPS first, then run:

```bash
sudo bash shadowrocket_vless_tcp_tls_install.sh install \
  --domain proxy.example.com \
  --email admin@example.com \
  --port 443 \
  --name my-vps
```

The script requests a Let's Encrypt certificate and prints a Shadowrocket line.

## IP-Only Mode

For a VPS without a domain:

```bash
sudo bash shadowrocket_vless_tcp_tls_install.sh install \
  --domain YOUR_VPS_IP \
  --self-signed \
  --port 443 \
  --name my-vps
```

This mode generates a self-signed certificate and the output link includes:

```text
allowInsecure=1
```

## Commands

Show the Shadowrocket line:

```bash
sudo shadowrocket-vless-tcp show
```

Check service, port, optimizer, and TCP settings:

```bash
sudo shadowrocket-vless-tcp status
```

Run the optimizer once:

```bash
sudo shadowrocket-vless-tcp optimizer-run
```

Uninstall systemd units and optimizer:

```bash
sudo shadowrocket-vless-tcp uninstall
```

## Adaptive TCP Optimizer

The installer enables a systemd timer:

```text
shadowrocket-vless-tcp-optimizer.timer
```

It runs every 60 seconds and:

- Counts established TCP connections on the configured port
- Switches between `normal` and `high_conn` TCP profiles
- Checks whether `xray.service` is active
- Checks whether the configured port is listening
- Restarts Xray after repeated health-check failures

Default thresholds:

```text
connections >= 1200 -> high_conn
connections <= 300  -> normal
```

## Requirements

- Debian or Ubuntu
- systemd
- root access
- TCP port 443 or your selected port open at the VPS firewall/security group
- TCP port 80 open when using Let's Encrypt standalone mode

## Security Notes

Do not commit live node links, root passwords, private keys, or generated UUIDs.

For production use, a real domain and Let's Encrypt certificate are preferred over self-signed IP-only mode.
