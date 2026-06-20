#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="/usr/local/bin/tcp-reality-single"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_ENV="/root/x420-client.env"
XRAY_URI="/root/x420-shadowrocket.uri"

usage() {
  cat <<'EOF'
x420 lean proxy installer

Goal:
  Minimal VLESS + REALITY + Vision over TCP/443 server for unstable routes.

Commands:
  install       install Xray, generate secrets, write config, tune TCP, restart
  gen-server    print Xray server config from environment variables
  gen-uri       print Shadowrocket VLESS REALITY URI from environment variables
  tune          apply stable TCP tuning: balanced + BBR + fq
  diagnose      print Xray, TCP, port, and recent log state
  validate      validate generated server JSON and shell syntax

Important env:
  SERVER_ADDR             VPS public IP or domain
  SERVER_PORT             default: 443
  XRAY_UUID               VLESS UUID
  REALITY_SERVER_NAME     default for install: www.tesla.com
  REALITY_TARGET_DOMAIN   default for install: www.tesla.com
  REALITY_PRIVATE_KEY     Xray x25519 private key
  REALITY_PUBLIC_KEY      Xray x25519 public key
  REALITY_SHORT_ID        8-16 hex recommended
  NODE_LABEL              default: x420
  TUNE_PROFILE            safe|balanced|fast, default: balanced
  SKIP_TUNE               set 1 to skip sysctl tuning during install
  XRAY_SOCKOPT            set 0 to disable Xray socket tuning
  XRAY_CONN_IDLE          default: 900
  XRAY_BUFFER_KB          default: 512
  XRAY_TCP_FAST_OPEN      default: 1024
  XRAY_TCP_KEEPALIVE_IDLE default: 60
  XRAY_TCP_KEEPALIVE_INTERVAL default: 30
  XRAY_TCP_USER_TIMEOUT   default: 60000

No QR, no firewall, no SSH hardening, no probes, no client config generator.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

is_placeholder() {
  [[ "${1:-}" == \<*\> ]]
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] && ! is_placeholder "$value" || die "missing env: $name"
}

validate_port() {
  local name="$1"
  local value="${!name:-}"
  [[ -z "$value" ]] && return 0
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be 1-65535"
  (( value >= 1 && value <= 65535 )) || die "$name must be 1-65535"
}

validate_nonnegative_int() {
  local name="$1"
  local value="${!name:-}"
  [[ -z "$value" ]] && return 0
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer"
}

validate_server_env() {
  require_env XRAY_UUID
  require_env REALITY_SERVER_NAME
  require_env REALITY_TARGET_DOMAIN
  require_env REALITY_PRIVATE_KEY
  require_env REALITY_SHORT_ID
  validate_port SERVER_PORT
  validate_nonnegative_int XRAY_CONN_IDLE
  validate_nonnegative_int XRAY_BUFFER_KB
  validate_nonnegative_int XRAY_TCP_FAST_OPEN
  validate_nonnegative_int XRAY_TCP_KEEPALIVE_IDLE
  validate_nonnegative_int XRAY_TCP_KEEPALIVE_INTERVAL
  validate_nonnegative_int XRAY_TCP_USER_TIMEOUT
}

validate_client_env() {
  require_env SERVER_ADDR
  require_env XRAY_UUID
  require_env REALITY_SERVER_NAME
  require_env REALITY_PUBLIC_KEY
  require_env REALITY_SHORT_ID
  validate_port SERVER_PORT
}

sysctl_key_exists() {
  local key="$1"
  [[ -e "/proc/sys/${key//./\/}" ]]
}

emit_sysctl_if_exists() {
  local key="$1"
  local value="$2"
  if sysctl_key_exists "$key"; then
    printf '%s=%s\n' "$key" "$value"
  else
    warn "skip missing sysctl key: $key"
  fi
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

detect_server_addr() {
  local ip
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || die "cannot detect public IPv4; set SERVER_ADDR"
  printf '%s' "$ip"
}

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    return 0
  fi
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

detect_tcp_congestion() {
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    printf 'bbr'
  fi
}

gen_sockopt() {
  [[ "${XRAY_SOCKOPT:-1}" == "1" ]] || return 0
  cat <<EOF
,
          "sockopt": {
            "tcpFastOpen": ${XRAY_TCP_FAST_OPEN:-1024},
            "tcpKeepAliveIdle": ${XRAY_TCP_KEEPALIVE_IDLE:-60},
            "tcpKeepAliveInterval": ${XRAY_TCP_KEEPALIVE_INTERVAL:-30},
            "tcpUserTimeout": ${XRAY_TCP_USER_TIMEOUT:-60000}
EOF
  if [[ -n "${XRAY_TCP_CONGESTION:-}" ]]; then
    printf ',\n            "tcpcongestion": "%s"\n' "$XRAY_TCP_CONGESTION"
  else
    printf '\n'
  fi
  cat <<EOF
          }
EOF
}

gen_server() {
  validate_server_env
  cat <<EOF
{
  "log": {
    "access": "none",
    "loglevel": "warning"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": ${XRAY_CONN_IDLE:-900},
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": false,
        "statsUserDownlink": false,
        "bufferSize": ${XRAY_BUFFER_KB:-512}
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false,
      "statsOutboundUplink": false,
      "statsOutboundDownlink": false
    }
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${SERVER_PORT:-443},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision",
            "email": "self-use"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_TARGET_DOMAIN}:443",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${REALITY_SHORT_ID}"
          ]
        }
$(gen_sockopt)
      },
      "sniffing": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

gen_uri() {
  validate_client_env
  local label="${NODE_LABEL:-x420}"
  local port="${SERVER_PORT:-443}"
  local encoded_label encoded_sni
  encoded_label="$(urlencode "$label")"
  encoded_sni="$(urlencode "$REALITY_SERVER_NAME")"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$XRAY_UUID" \
    "$SERVER_ADDR" \
    "$port" \
    "$encoded_sni" \
    "$REALITY_PUBLIC_KEY" \
    "$REALITY_SHORT_ID" \
    "$encoded_label"
}

tune() {
  need_root
  local sysctl_file="/etc/sysctl.d/99-x420-lean.conf"
  local has_bbr="0"
  local profile="${TUNE_PROFILE:-balanced}"
  case "$profile" in
    safe|balanced|fast) ;;
    *) die "TUNE_PROFILE must be safe, balanced, or fast" ;;
  esac
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    has_bbr="1"
    printf 'tcp_bbr\n' > /etc/modules-load.d/bbr.conf
  else
    warn "BBR is not exposed by this kernel"
  fi
  {
    printf '# x420 TCP tuning profile: %s\n' "$profile"
    emit_sysctl_if_exists net.core.somaxconn 8192
    emit_sysctl_if_exists net.core.default_qdisc fq
    emit_sysctl_if_exists net.core.netdev_max_backlog 16384
    emit_sysctl_if_exists net.core.rmem_max 67108864
    emit_sysctl_if_exists net.core.wmem_max 67108864
    emit_sysctl_if_exists net.ipv4.tcp_max_syn_backlog 8192
    emit_sysctl_if_exists net.ipv4.tcp_syncookies 1
    emit_sysctl_if_exists net.ipv4.tcp_fastopen 3
    emit_sysctl_if_exists net.ipv4.tcp_fin_timeout 15
    emit_sysctl_if_exists net.ipv4.tcp_keepalive_time 600
    emit_sysctl_if_exists net.ipv4.tcp_keepalive_intvl 30
    emit_sysctl_if_exists net.ipv4.tcp_keepalive_probes 5
    emit_sysctl_if_exists net.ipv4.ip_local_port_range "10240 65535"
    emit_sysctl_if_exists net.ipv4.tcp_mtu_probing 1
    emit_sysctl_if_exists net.ipv4.tcp_moderate_rcvbuf 1
    emit_sysctl_if_exists net.ipv4.tcp_no_metrics_save 1
    emit_sysctl_if_exists net.ipv4.tcp_slow_start_after_idle 0
    emit_sysctl_if_exists net.ipv4.tcp_tw_reuse 1
    emit_sysctl_if_exists net.ipv4.tcp_notsent_lowat 16384
    emit_sysctl_if_exists net.ipv4.tcp_rmem "4096 87380 33554432"
    emit_sysctl_if_exists net.ipv4.tcp_wmem "4096 65536 33554432"
    if [[ "$profile" == "fast" ]]; then
      emit_sysctl_if_exists net.core.somaxconn 16384
      emit_sysctl_if_exists net.core.netdev_max_backlog 250000
      emit_sysctl_if_exists net.core.rmem_max 134217728
      emit_sysctl_if_exists net.core.wmem_max 134217728
      emit_sysctl_if_exists net.ipv4.tcp_max_syn_backlog 16384
      emit_sysctl_if_exists net.ipv4.tcp_syn_retries 4
      emit_sysctl_if_exists net.ipv4.tcp_synack_retries 3
      emit_sysctl_if_exists net.ipv4.tcp_rmem "4096 87380 67108864"
      emit_sysctl_if_exists net.ipv4.tcp_wmem "4096 65536 67108864"
    fi
    if [[ "$has_bbr" == "1" ]]; then
      emit_sysctl_if_exists net.ipv4.tcp_congestion_control bbr
    fi
  } > "$sysctl_file"
  sysctl --system >/dev/null || warn "sysctl --system returned non-zero"
  sysctl \
    net.ipv4.tcp_congestion_control \
    net.core.default_qdisc \
    net.ipv4.tcp_fastopen \
    net.core.netdev_max_backlog \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem 2>/dev/null || true
}

install_systemd_override() {
  need_root
  command -v systemctl >/dev/null 2>&1 || return 0
  install -d -m 0755 /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/10-x420-lean.conf <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=infinity
Restart=on-failure
RestartSec=3s
ExecStartPre=/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
EOF
  systemctl daemon-reload
}

install_server_config() {
  need_root
  install -d -m 0755 /usr/local/etc/xray
  gen_server > /tmp/x420-lean-config.json
  python3 -m json.tool /tmp/x420-lean-config.json >/dev/null
  install -m 640 /tmp/x420-lean-config.json "$XRAY_CONFIG"
  if getent passwd nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1; then
    chown nobody:nogroup "$XRAY_CONFIG"
  fi
  xray run -test -config "$XRAY_CONFIG"
}

install_all() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates unzip openssl python3
  install_xray
  install -m 0755 "$0" "$SCRIPT_PATH"

  SERVER_ADDR="${SERVER_ADDR:-$(detect_server_addr)}"
  SERVER_PORT="${SERVER_PORT:-443}"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.tesla.com}"
  REALITY_TARGET_DOMAIN="${REALITY_TARGET_DOMAIN:-www.tesla.com}"
  NODE_LABEL="${NODE_LABEL:-x420}"
  XRAY_UUID="${XRAY_UUID:-$(xray uuid)}"

  local key_output
  key_output="$(xray x25519)"
  REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-$(printf '%s\n' "$key_output" | awk -F': ' '/^PrivateKey:/ {print $2}')}"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-$(printf '%s\n' "$key_output" | awk -F': ' '/^Password \(PublicKey\):/ {print $2}')}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
  XRAY_TCP_CONGESTION="${XRAY_TCP_CONGESTION:-$(detect_tcp_congestion)}"
  export SERVER_ADDR SERVER_PORT XRAY_UUID
  export REALITY_SERVER_NAME REALITY_TARGET_DOMAIN
  export REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID NODE_LABEL
  export XRAY_TCP_CONGESTION

  install_server_config
  if [[ "${SKIP_TUNE:-0}" != "1" ]]; then
    tune
  fi
  install_systemd_override
  systemctl enable xray >/dev/null
  systemctl reset-failed xray || true
  systemctl restart xray
  systemctl is-active xray >/dev/null

  cat > "$XRAY_ENV" <<EOF
export SERVER_ADDR="${SERVER_ADDR}"
export SERVER_PORT="${SERVER_PORT}"
export XRAY_UUID="${XRAY_UUID}"
export REALITY_SERVER_NAME="${REALITY_SERVER_NAME}"
export REALITY_TARGET_DOMAIN="${REALITY_TARGET_DOMAIN}"
export REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
export REALITY_SHORT_ID="${REALITY_SHORT_ID}"
export NODE_LABEL="${NODE_LABEL}"
EOF
  chmod 600 "$XRAY_ENV"
  gen_uri > "$XRAY_URI"
  chmod 600 "$XRAY_URI"

  echo "x420 lean installed"
  echo "service: $(systemctl is-active xray)"
  echo "uri: $XRAY_URI"
  cat "$XRAY_URI"
}

validate() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  export XRAY_UUID="${XRAY_UUID:-00000000-0000-4000-8000-000000000000}"
  export REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.tesla.com}"
  export REALITY_TARGET_DOMAIN="${REALITY_TARGET_DOMAIN:-www.tesla.com}"
  export REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-PRIVATE_KEY_PLACEHOLDER}"
  export REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-PUBLIC_KEY_PLACEHOLDER}"
  export REALITY_SHORT_ID="${REALITY_SHORT_ID:-0123456789abcdef}"
  export SERVER_ADDR="${SERVER_ADDR:-127.0.0.1}"
  export XRAY_TCP_CONGESTION="${XRAY_TCP_CONGESTION:-bbr}"
  gen_server > "$tmp/server.json"
  python3 -m json.tool "$tmp/server.json" >/dev/null
  gen_uri >/dev/null
  bash -n "$0"
  echo "validation ok"
}

diagnose() {
  echo "== x420 diagnose =="
  date '+time: %Y-%m-%d %H:%M:%S %z'
  echo

  echo "== xray =="
  if command -v xray >/dev/null 2>&1; then
    xray version 2>/dev/null | sed -n '1,2p' || true
    xray run -test -config "$XRAY_CONFIG" || true
  else
    warn "xray not found"
  fi
  echo

  echo "== service =="
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active xray || true
    systemctl status xray --no-pager -l 2>/dev/null | sed -n '1,20p' || true
  else
    warn "systemctl not found"
  fi
  echo

  echo "== listen =="
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E "(:${SERVER_PORT:-443} )|(:${SERVER_PORT:-443}$)" || true
  else
    warn "ss not found"
  fi
  echo

  echo "== tcp =="
  sysctl \
    net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_available_congestion_control \
    net.core.default_qdisc \
    net.ipv4.tcp_fastopen \
    net.core.netdev_max_backlog \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem 2>/dev/null || true
  echo

  echo "== target timing =="
  if command -v curl >/dev/null 2>&1; then
    curl -4sSI --max-time 8 -o /dev/null \
      -w 'remote_ip=%{remote_ip} connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n' \
      "https://${REALITY_TARGET_DOMAIN:-www.tesla.com}/" || true
  else
    warn "curl not found"
  fi
  echo

  echo "== recent logs =="
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u xray -n 50 --no-pager 2>/dev/null || true
  fi
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  install) install_all "$@" ;;
  gen-server) gen_server "$@" ;;
  gen-uri) gen_uri "$@" ;;
  tune) tune "$@" ;;
  diagnose) diagnose "$@" ;;
  validate) validate "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
