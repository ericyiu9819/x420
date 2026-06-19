# x420

TCP-only REALITY proxy installer for Debian/Ubuntu VPS.

Core protocol:

```text
VLESS + REALITY + Vision over TCP/443
```

Design:

- Single protocol and single outbound path.
- No UDP transport, selector, urltest, fallback, or chained proxy.
- Server keeps one Xray inbound and direct/block outbounds.
- Client config provides local sing-box SOCKS and HTTP inbounds.
- Private IP ranges and local domains go direct; other traffic uses proxy.
- Optional TCP tuning for BBR-capable systems, using `aggressive` by default.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh)
```

Optional variables:

```bash
SERVER_ADDR=1.2.3.4 \
SERVER_PORT=443 \
REALITY_SERVER_NAME=www.microsoft.com \
REALITY_TARGET_DOMAIN=www.microsoft.com \
NODE_LABEL=x420 \
SKIP_TUNE=0 \
TCP_TUNE_PROFILE=aggressive \
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh)
```

The installer writes:

```text
/usr/local/bin/tcp-reality-single
/usr/local/etc/xray/config.json
/etc/systemd/system/xray.service.d/10-x420.conf
/root/x420-client.env
/root/x420-shadowrocket.uri
/root/x420-shadowrocket.svg
```

Firewall configuration is skipped by default. If you explicitly enable it with
`SKIP_FIREWALL=0`, the script allows only `22/tcp` and the selected proxy port.

## Local Usage

Generate secrets:

```bash
./tcp-reality-single.sh make-secrets > secrets.env
. ./secrets.env
```

Generate server config:

```bash
./tcp-reality-single.sh gen-server > xray-server.json
```

Generate sing-box client config:

```bash
./tcp-reality-single.sh gen-client > sing-box-client.json
```

Generate Shadowrocket link and QR code:

```bash
./tcp-reality-single.sh gen-shadowrocket-uri
./tcp-reality-single.sh gen-shadowrocket-qr shadowrocket.svg
```

Validate generated JSON:

```bash
./tcp-reality-single.sh validate
```

## TCP Tuning

Enable tuning during install:

```bash
SKIP_TUNE=0 TCP_TUNE_PROFILE=aggressive bash install.sh
```

`aggressive` is the default profile. Use `balanced` only when the VPS has low
memory or the provider behaves poorly with larger TCP buffers:

```bash
SKIP_TUNE=0 TCP_TUNE_PROFILE=balanced bash install.sh
```

Profiles:

```text
balanced:
  rmem_max/wmem_max = 64 MiB
  tcp_rmem/tcp_wmem max = 32 MiB
  somaxconn/tcp_max_syn_backlog = 8192

aggressive:
  rmem_max/wmem_max = 128 MiB
  tcp_rmem/tcp_wmem max = 64 MiB
  somaxconn/tcp_max_syn_backlog = 16384
```

The script keeps one queue-related performance setting:

```text
net.core.default_qdisc = fq
```

This is paired with `net.ipv4.tcp_congestion_control = bbr` for better TCP pacing
on BBR-capable kernels. It does not install custom kernels or add extra queue
logic. The tuning command only writes sysctl keys present under `/proc/sys`, so
minimal VPS images can skip unsupported options without failing the install.

Check the current state:

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing
```

## Diagnostics

Observe server state:

```bash
./tcp-reality-single.sh observe
```

Compare direct and proxy latency:

```bash
./tcp-reality-single.sh probe-direct https://www.gstatic.com/generate_204 10
./tcp-reality-single.sh probe-proxy socks5h://127.0.0.1:1080 https://www.gstatic.com/generate_204 20
```

## Security

- Secrets are generated on the VPS.
- Do not publish `/root/x420-client.env` or generated import URIs.
- Prefer SSH key login and disable password login after confirming access.
- This project is intended for lawful administration of your own VPS and network.
