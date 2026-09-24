#!/usr/bin/env bash
# shared helpers for VLESS no-redundant scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SNI="www.apple.com"
DEFAULT_DEST="www.apple.com:443"
DEFAULT_PORT="443"
DEFAULT_FP="chrome"
DEFAULT_NETWORK="tcp"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行（sudo -i 后再执行）"
}

detect_public_ip() {
  local ip=""
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com"; do
    ip="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

parse_x25519() {
  local raw="$1"
  PRIVATE_KEY="$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*(PrivateKey|Private key)[[:space:]]*:[[:space:]]*//p' | head -n1 | tr -d '[:space:]')"
  PUBLIC_KEY="$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*(Password \(PublicKey\)|Password|PublicKey|Public key)[[:space:]]*:[[:space:]]*//p' | head -n1 | tr -d '[:space:]')"
  if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
    printf 'ERROR: cannot parse xray x25519 output:\n%s\n' "$raw" >&2
    exit 1
  fi
}

gen_short_id() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

write_secrets_env() {
  local file="$1"
  cat >"$file" <<EOF
# VLESS no-redundant credentials — keep private
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${SNI}
DEST=${DEST}
PORT=${PORT}
SERVER_ADDR=${SERVER_ADDR:-}
NETWORK=${NETWORK}
FINGERPRINT=${FINGERPRINT}
FLOW=xtls-rprx-vision
MUX=false
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$file"
}

load_secrets_env() {
  local file="$1"
  [[ -f "$file" ]] || die "找不到密钥文件: $file"
  set -a
  # shellcheck disable=SC1091
  source <(grep -E '^[A-Z0-9_]+=' "$file")
  set +a
  : "${UUID:?missing UUID}"
  : "${PRIVATE_KEY:?missing PRIVATE_KEY}"
  : "${PUBLIC_KEY:?missing PUBLIC_KEY}"
  : "${SHORT_ID:?missing SHORT_ID}"
  : "${SNI:?missing SNI}"
  : "${PORT:?missing PORT}"
  DEST="${DEST:-www.apple.com:443}"
  NETWORK="${NETWORK:-tcp}"
  FINGERPRINT="${FINGERPRINT:-chrome}"
  FLOW="${FLOW:-xtls-rprx-vision}"
}

build_share_link() {
  local host="$1"
  local name="${2:-vless-nr}"
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=%s#%s\n' \
    "$UUID" "$host" "$PORT" \
    "${FLOW:-xtls-rprx-vision}" "$SNI" "${FINGERPRINT:-chrome}" \
    "$PUBLIC_KEY" "$SHORT_ID" "${NETWORK:-tcp}" "$(urlencode "$name")"
}

render_server_json() {
  python3 - "$@" <<'PY'
import json, sys
uuid, port, sni, dest, private_key, short_id, network = sys.argv[1:8]
cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": int(port),
    "protocol": "vless",
    "settings": {
      "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": network,
      "security": "reality",
      "realitySettings": {
        "show": False,
        "dest": dest,
        "xver": 0,
        "serverNames": [sni],
        "privateKey": private_key,
        "shortIds": [short_id]
      }
    },
    "sniffing": {
      "enabled": True,
      "destOverride": ["http", "tls", "quic"]
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
print(json.dumps(cfg, ensure_ascii=False, indent=2))
PY
}

render_client_json() {
  python3 - "$@" <<'PY'
import json, sys
server, port, uuid, sni, public_key, short_id, network, fingerprint, mixed_port = sys.argv[1:10]
cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": int(mixed_port),
    "protocol": "mixed",
    "settings": {"udp": True},
    "sniffing": {
      "enabled": True,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": True
    },
    "tag": "mixed-in"
  }],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": server,
          "port": int(port),
          "users": [{
            "id": uuid,
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }]
        }]
      },
      "streamSettings": {
        "network": network,
        "security": "reality",
        "realitySettings": {
          "serverName": sni,
          "fingerprint": fingerprint,
          "publicKey": public_key,
          "shortId": short_id,
          "spiderX": ""
        }
      },
      "mux": {"enabled": False},
      "tag": "proxy"
    },
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
      {"type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"}
    ]
  }
}
print(json.dumps(cfg, ensure_ascii=False, indent=2))
PY
}

enable_bbr() {
  require_root
  local sysctl_file="/etc/sysctl.d/99-vless-nr-bbr.conf"
  local mod_file="/etc/modules-load.d/vless-nr-bbr.conf"

  if [[ ! -d /proc/sys/net/ipv4 ]]; then
    echo "WARN: 非 Linux 或不支持 sysctl，跳过 BBR" >&2
    return 1
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
  fi
  if [[ -d /etc/modules-load.d ]]; then
    printf 'tcp_bbr\n' >"$mod_file"
  fi

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -Eq '(^|[[:space:]])bbr([[:space:]]|$)'; then
    echo "WARN: 当前内核未提供 BBR，跳过" >&2
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true
    return 1
  fi

  mkdir -p /etc/sysctl.d
  cat >"$sysctl_file" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  sysctl -p "$sysctl_file" >/dev/null
  echo "BBR 已启用:"
  echo "  tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "  default_qdisc=$(sysctl -n net.core.default_qdisc)"
  echo "  persist=$sysctl_file"
}

show_bbr_status() {
  echo "==> BBR / qdisc"
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    echo "tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control)"
    echo "tcp_available_congestion_control=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    echo "default_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    lsmod 2>/dev/null | grep -E '^tcp_bbr' || echo "tcp_bbr module: not loaded or built-in"
    [[ -f /etc/sysctl.d/99-vless-nr-bbr.conf ]] && echo "persist: /etc/sysctl.d/99-vless-nr-bbr.conf" || echo "persist: missing"
  else
    echo "BBR status unavailable on this host"
  fi
}

