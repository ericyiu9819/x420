# x420 VLESS REALITY Setup

Single-script VLESS REALITY deployment for Xray.

```text
Client -> VLESS + TCP + REALITY + XTLS Vision -> Xray:443 -> freedom direct
```

## Script

- `scripts/setup-vless-reality.sh`

Run it on a Linux VPS as root. It installs or reuses Xray, writes a minimal VLESS REALITY server config, applies conservative network performance tuning, restarts Xray, and outputs client import assets.

## Usage

```bash
SERVER_ADDRESS=<server_ip_or_domain> bash scripts/setup-vless-reality.sh
```

Preserve an existing node identity during an in-place upgrade:

```bash
UUID=<current_uuid> \
SHORT_ID=<current_short_id> \
REALITY_PRIVATE_KEY=<current_private_key> \
REALITY_PUBLIC_KEY=<current_public_key> \
SERVER_ADDRESS=<server_ip_or_domain> \
bash scripts/setup-vless-reality.sh
```

## Performance Tuning

Enabled by default:

- BBR + `fq`
- TCP Fast Open
- Xray `sockopt.tcpFastOpen`
- Xray `sockopt.tcpNoDelay`
- `tcp_mtu_probing=1`
- larger TCP connection queues
- larger TCP buffer ceilings
- systemd resource limits for Xray

Disable tuning layers when needed:

```bash
ENABLE_NETWORK_OPTIMIZATION=0 bash scripts/setup-vless-reality.sh
ENABLE_XRAY_SOCKOPT=0 bash scripts/setup-vless-reality.sh
ENABLE_SYSTEMD_LIMITS=0 bash scripts/setup-vless-reality.sh
```

## Security

Do not commit generated real configs, import links, UUID/key pairs, VPS passwords, or deployment records. See `SECURITY.md`.
