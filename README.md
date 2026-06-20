# x420

Minimal VLESS REALITY proxy installer for unstable VPS routes.

Core path:

```text
Shadowrocket -> VLESS REALITY Vision TCP/443 -> Xray -> direct
```

## Design

- Single Xray inbound on TCP/443.
- No QR generator, probe tool, firewall helper, SSH hardening, mux, fallback, or multi-node logic.
- Stable tuning only: `balanced + BBR + fq`.
- `tcp_fastopen=3`, enabling both client and server side when the kernel supports it.
- Xray socket tuning is enabled by default: TCP Fast Open, TCP keepalive, user timeout, and BBR per socket when available.
- Xray access log is disabled.
- UDP is not globally blocked, so browser and video traffic can keep their natural behavior.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh)
```

Common overrides:

```bash
SERVER_ADDR=1.2.3.4 \
SERVER_PORT=443 \
REALITY_SERVER_NAME=www.tesla.com \
REALITY_TARGET_DOMAIN=www.tesla.com \
NODE_LABEL=x420 \
TUNE_PROFILE=balanced \
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh)
```

The installer writes:

```text
/usr/local/bin/tcp-reality-single
/usr/local/etc/xray/config.json
/etc/systemd/system/xray.service.d/10-x420-lean.conf
/root/x420-client.env
/root/x420-shadowrocket.uri
```

## Commands

```bash
./tcp-reality-single.sh install
./tcp-reality-single.sh gen-server
./tcp-reality-single.sh gen-uri
./tcp-reality-single.sh tune
./tcp-reality-single.sh diagnose
./tcp-reality-single.sh validate
```

## TCP Tuning

Default tuning is balanced:

```text
BBR + fq
rmem_max/wmem_max = 64 MiB
tcp_rmem/tcp_wmem max = 32 MiB
somaxconn/tcp_max_syn_backlog = 8192
tcp_fastopen = 3
netdev_max_backlog = 16384
tcp_no_metrics_save = 1
tcp_moderate_rcvbuf = 1
```

Profiles:

```bash
TUNE_PROFILE=safe ./tcp-reality-single.sh tune
TUNE_PROFILE=balanced ./tcp-reality-single.sh tune
TUNE_PROFILE=fast ./tcp-reality-single.sh tune
```

Use `fast` only on a dedicated proxy VPS with enough memory:

```text
rmem_max/wmem_max = 128 MiB
tcp_rmem/tcp_wmem max = 64 MiB
somaxconn/tcp_max_syn_backlog = 16384
netdev_max_backlog = 250000
```

Skip tuning during install:

```bash
SKIP_TUNE=1 bash install.sh
```

Check state:

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_fastopen
sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
```

Run diagnostics:

```bash
./tcp-reality-single.sh diagnose
```

## Validation

```bash
bash -n tcp-reality-single.sh install.sh
./tcp-reality-single.sh validate
./tcp-reality-single.sh gen-server | python3 -m json.tool
```

## Security

- Secrets are generated on the VPS.
- Do not publish `/root/x420-client.env` or `/root/x420-shadowrocket.uri`.
- Use SSH keys and rotate root passwords after installation.
