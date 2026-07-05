#!/usr/bin/env bash
set -Eeuo pipefail

# One-hop VLESS TCP REALITY Vision installer for systemd Linux servers.
# Target topology:
#   client -> VLESS/TCP/REALITY/Vision -> this server -> direct outbound

PORT="${XRAY_PORT:-443}"
SNI="${REALITY_SNI:-www.cloudflare.com}"
DEST="${REALITY_DEST:-www.cloudflare.com:443}"
SERVER_ADDR="${SERVER_ADDR:-}"
UUID="${XRAY_UUID:-}"
SHORT_ID="${REALITY_SHORT_ID:-}"
ENABLE_BBR=1
OPEN_FIREWALL=1
INSTALL_XRAY=1
PURGE_OLD=0
CONFIG_PATH="/usr/local/etc/xray/config.json"
INSTALL_SCRIPT_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

usage() {
  cat <<'EOF'
Usage:
  bash install-vless-reality.sh [options]

Options:
  --port <port>              Listen TCP port. Default: 443
  --sni <domain>             REALITY serverName. Default: www.cloudflare.com
  --dest <host:port>         REALITY dest. Default: www.cloudflare.com:443
  --server <domain_or_ip>    Address shown in client link. Auto-detected if omitted.
  --uuid <uuid>              Use an existing VLESS UUID.
  --short-id <hex>           Use an existing REALITY shortId, even-length hex, max 16 chars.
  --no-bbr                   Do not apply BBR/fq sysctl tuning.
  --no-firewall              Do not try to open the TCP port in ufw/firewalld.
  --no-install               Do not install/upgrade Xray; only rewrite config.
  --purge-old                Delete old Xray configs, backups and service drop-ins before writing.
  -h, --help                 Show help.

Environment variables:
  XRAY_PORT, REALITY_SNI, REALITY_DEST, SERVER_ADDR, XRAY_UUID, REALITY_SHORT_ID

Example:
  bash install-vless-reality.sh --port 443 --sni www.cloudflare.com --dest www.cloudflare.com:443
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root."
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "This script targets systemd Linux servers."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        PORT="${2:-}"
        shift 2
        ;;
      --sni)
        SNI="${2:-}"
        shift 2
        ;;
      --dest)
        DEST="${2:-}"
        shift 2
        ;;
      --server)
        SERVER_ADDR="${2:-}"
        shift 2
        ;;
      --uuid)
        UUID="${2:-}"
        shift 2
        ;;
      --short-id)
        SHORT_ID="${2:-}"
        shift 2
        ;;
      --no-bbr)
        ENABLE_BBR=0
        shift
        ;;
      --no-firewall)
        OPEN_FIREWALL=0
        shift
        ;;
      --no-install)
        INSTALL_XRAY=0
        shift
        ;;
      --purge-old)
        PURGE_OLD=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_inputs() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Invalid port: $PORT"
  (( PORT >= 1 && PORT <= 65535 )) || die "Port out of range: $PORT"
  [[ -n "$SNI" ]] || die "SNI cannot be empty."
  [[ -n "$DEST" ]] || die "Dest cannot be empty."

  if [[ "$DEST" != *:* ]]; then
    DEST="${DEST}:443"
  fi

  if [[ -n "$SHORT_ID" ]]; then
    [[ "$SHORT_ID" =~ ^[0-9a-fA-F]*$ ]] || die "shortId must be hex."
    (( ${#SHORT_ID} <= 16 )) || die "shortId length must be <= 16."
    (( ${#SHORT_ID} % 2 == 0 )) || die "shortId length must be even."
  fi
}

install_packages() {
  log "Installing required packages."

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl ca-certificates openssl
  else
    warn "No supported package manager found; assuming curl, ca-certificates and openssl exist."
  fi
}

install_xray() {
  if [[ "$INSTALL_XRAY" -eq 0 ]]; then
    log "Skipping Xray install/upgrade."
    command -v xray >/dev/null 2>&1 || die "xray is not installed, remove --no-install."
    return
  fi

  log "Installing/upgrading Xray from official XTLS installer."
  bash -c "$(curl -fsSL "$INSTALL_SCRIPT_URL")" @ install
}

purge_old_xray_state() {
  if [[ "$PURGE_OLD" -eq 0 ]]; then
    return
  fi

  log "Purging old Xray configs and service drop-ins."

  if systemctl list-unit-files xray.service >/dev/null 2>&1; then
    systemctl stop xray >/dev/null 2>&1 || true
  fi

  if [[ -d /usr/local/etc/xray ]]; then
    find /usr/local/etc/xray -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi

  if [[ -d /etc/systemd/system/xray.service.d ]]; then
    find /etc/systemd/system/xray.service.d -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi

  if [[ -d /etc/systemd/system/xray@.service.d ]]; then
    find /etc/systemd/system/xray@.service.d -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
}

generate_uuid() {
  if [[ -n "$UUID" ]]; then
    return
  fi

  if command -v xray >/dev/null 2>&1; then
    UUID="$(xray uuid)"
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  else
    UUID="$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
  fi
}

generate_short_id() {
  if [[ -n "$SHORT_ID" ]]; then
    SHORT_ID="$(printf '%s' "$SHORT_ID" | tr 'A-F' 'a-f')"
    return
  fi

  SHORT_ID="$(openssl rand -hex 8)"
}

generate_reality_keys() {
  command -v xray >/dev/null 2>&1 || die "xray command not found after install."

  local output
  output="$(xray x25519)"
  PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) == "private key" || $1 == "PrivateKey" {print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) == "public key" || $1 == "PublicKey" || $1 == "Password (PublicKey)" {print $2; exit}')"

  [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]] || die "Failed to generate REALITY x25519 keys."
}

detect_server_addr() {
  if [[ -n "$SERVER_ADDR" ]]; then
    return
  fi

  SERVER_ADDR="$(
    curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null ||
    curl -4fsS --max-time 6 https://ifconfig.me 2>/dev/null ||
    true
  )"

  if [[ -z "$SERVER_ADDR" ]]; then
    SERVER_ADDR="YOUR_SERVER_IP"
    warn "Could not auto-detect server address. Replace YOUR_SERVER_IP in the client link."
  fi
}

write_xray_config() {
  log "Writing Xray config to $CONFIG_PATH."
  install -d -m 755 "$(dirname "$CONFIG_PATH")"
  install -d -m 755 /var/log/xray

  if [[ "$PURGE_OLD" -eq 0 && -f "$CONFIG_PATH" ]]; then
    local backup_path
    backup_path="${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_PATH" "$backup_path"
    log "Existing config backed up to $backup_path."
  fi

  cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 8,
        "connIdle": 1800,
        "uplinkOnly": 20,
        "downlinkOnly": 20,
        "bufferSize": 4
      }
    }
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "network": "udp",
        "port": "443",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-tcp-reality-vision",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "tcp-user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        },
        "sockopt": {
          "tcpFastOpen": 256,
          "tcpKeepAliveIdle": 300,
          "tcpKeepAliveInterval": 30,
          "tcpcongestion": "bbr"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "tcpKeepAliveIdle": 300,
          "tcpKeepAliveInterval": 30,
          "tcpcongestion": "bbr"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

  chmod 644 "$CONFIG_PATH"
}

apply_bbr() {
  if [[ "$ENABLE_BBR" -eq 0 ]]; then
    log "Skipping BBR/fq tuning."
    return
  fi

  log "Applying TCP performance tuning."
  cat > /etc/sysctl.d/99-xray-vless-performance.conf <<'EOF'
net.core.default_qdisc = fq
net.core.somaxconn = 32768
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_local_port_range = 10000 65535
EOF

  sysctl --system >/dev/null || warn "sysctl reload failed; check kernel support for bbr/fq."
}

write_xray_service_override() {
  log "Writing Xray systemd long-connection override."
  install -d -m 755 /etc/systemd/system/xray.service.d

  cat > /etc/systemd/system/xray.service.d/30-long-connection.conf <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF

  systemctl daemon-reload >/dev/null
}

open_firewall_port() {
  if [[ "$OPEN_FIREWALL" -eq 0 ]]; then
    log "Skipping firewall changes."
    return
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "Opening TCP/$PORT in ufw."
    ufw allow "$PORT/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "Opening TCP/$PORT in firewalld."
    firewall-cmd --add-port="${PORT}/tcp" --permanent
    firewall-cmd --reload
  else
    log "No active ufw/firewalld detected; skipping firewall changes."
  fi
}

restart_xray() {
  log "Validating Xray config."
  xray run -test -config "$CONFIG_PATH"

  log "Restarting Xray service."
  systemctl enable xray >/dev/null
  systemctl restart xray
}

print_result() {
  local addr="$SERVER_ADDR"
  if [[ "$addr" == *:* && "$addr" != \[*\] ]]; then
    addr="[$addr]"
  fi

  local link
  link="vless://${UUID}@${addr}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#vless-tcp-reality"

  cat <<EOF

Done.

Server:
  address:   $SERVER_ADDR
  port:      $PORT
  protocol:  VLESS
  transport: TCP
  security:  REALITY
  flow:      xtls-rprx-vision
  sni:       $SNI
  dest:      $DEST
  uuid:      $UUID
  publicKey: $PUBLIC_KEY
  shortId:   $SHORT_ID

Client link:
  $link

Useful commands:
  systemctl status xray --no-pager
  journalctl -u xray -f
  xray run -test -config $CONFIG_PATH
EOF
}

main() {
  parse_args "$@"
  validate_inputs
  require_root
  require_systemd
  install_packages
  install_xray
  purge_old_xray_state
  generate_uuid
  generate_short_id
  generate_reality_keys
  detect_server_addr
  write_xray_config
  apply_bbr
  write_xray_service_override
  open_firewall_port
  restart_xray
  print_result
}

main "$@"
