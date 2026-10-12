#!/usr/bin/env bash
# VLESS + TCP + REALITY + Vision
# dest/SNI: www.tesla.com
set -euo pipefail

REALITY_DEST="www.tesla.com:443"
REALITY_SNI="www.tesla.com"
LISTEN_PORT="${LISTEN_PORT:-443}"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
CLIENT_FILE="/usr/local/etc/xray/client.env"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "用 root 跑: sudo bash $0"
    exit 1
  fi
}

check_dest() {
  echo "== 检查握手站 ${REALITY_SNI} =="
  python3 - <<'PY' || true
import socket, ssl, sys
host = "www.tesla.com"
ctx = ssl.create_default_context()
ctx.set_alpn_protocols(["h2", "http/1.1"])
with socket.create_connection((host, 443), timeout=10) as raw:
    with ctx.wrap_socket(raw, server_hostname=host) as s:
        print("TLS:", s.version())
        print("ALPN:", s.selected_alpn_protocol())
        print("Cipher:", s.cipher())
        if s.version() != "TLSv1.3":
            sys.exit(2)
        if s.selected_alpn_protocol() != "h2":
            print("WARN: ALPN 不是 h2，Reality 可能不稳定")
PY
  if command -v xray >/dev/null 2>&1; then
    xray tls ping "${REALITY_SNI}" || true
  fi
}

install_xray() {
  echo "== 安装 / 更新 Xray =="
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

gen_secrets() {
  echo "== UUID / Reality 密钥 / shortId =="
  if [[ "${FORCE_NEW_KEYS:-0}" != "1" && -f "${CLIENT_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CLIENT_FILE}"
    if [[ -n "${UUID:-}" && -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" && -n "${SHORT_ID:-}" ]]; then
      echo "复用已有密钥: ${CLIENT_FILE}（FORCE_NEW_KEYS=1 才换新）"
      return
    fi
  fi
  UUID="$(xray uuid)"
  mapfile -t KEYS < <(xray x25519)
  PRIVATE_KEY=""
  PUBLIC_KEY=""
  for line in "${KEYS[@]}"; do
    case "$line" in
      Private*) PRIVATE_KEY="${line##*: }" ;;
      Password*) PUBLIC_KEY="${line##*: }" ;;
      Public*) PUBLIC_KEY="${line##*: }" ;;
    esac
  done
  SHORT_ID="$(openssl rand -hex 8)"
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$UUID" ]]; then
    echo "密钥生成失败"
    printf '%s\n' "${KEYS[@]}"
    exit 1
  fi
}

write_config() {
  echo "== 写 ${XRAY_CONFIG} =="
  mkdir -p /usr/local/etc/xray
  cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "tesla-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "target": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
  xray run -test -c "${XRAY_CONFIG}"
}

enable_bbr() {
  echo "== 尝试开启 BBR =="
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    cat >/etc/sysctl.d/99-vless-bbr.conf <<'SYS'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYS
    sysctl --system >/dev/null
  else
    echo "内核无 BBR，跳过"
  fi
}

open_port() {
  echo "== 放行 TCP ${LISTEN_PORT} =="
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${LISTEN_PORT}/tcp" || true
  fi
  iptables -C INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT || true
}

start_xray() {
  systemctl enable xray
  systemctl restart xray
  systemctl --no-pager --full status xray | sed -n '1,20p'
}

print_client() {
  SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || curl -4 -fsS --max-time 8 https://ifconfig.me || hostname -I | awk '{print $1}')"
  LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#tesla-vision"
  cat > "${CLIENT_FILE}" <<EOF
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${REALITY_SNI}
DEST=${REALITY_DEST}
SERVER_IP=${SERVER_IP}
PORT=${LISTEN_PORT}
LINK=${LINK}
EOF
  chmod 600 "${CLIENT_FILE}"
  cat <<EOF

======== 部署完成 ========
握手站: ${REALITY_SNI}
参数文件: ${CLIENT_FILE}

address : ${SERVER_IP}
port    : ${LISTEN_PORT}
uuid    : ${UUID}
flow    : xtls-rprx-vision
network : tcp
security: reality
sni     : ${REALITY_SNI}
fp      : chrome
pbk     : ${PUBLIC_KEY}
sid     : ${SHORT_ID}

${LINK}

注意:
1. 只用 www.tesla.com，不要用 tesla.com。
2. 云安全组放行 TCP ${LISTEN_PORT}。
3. 复核: xray tls ping www.tesla.com
4. Akamai 可能对 HTTP 返回 403，TLS1.3+h2 握手成功即可。
EOF
}

main() {
  need_root
  check_dest
  install_xray
  check_dest
  gen_secrets
  write_config
  enable_bbr
  open_port
  start_xray
  print_client
}

main "$@"
