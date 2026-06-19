#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/ericyiu9819/x420/main}"
SCRIPT_URL="${SCRIPT_URL:-${REPO_RAW_BASE}/tcp-reality-single.sh}"
SCRIPT_PATH="/usr/local/bin/tcp-reality-single"
SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
TARGET_DOMAIN="${REALITY_TARGET_DOMAIN:-www.microsoft.com}"
SERVER_PORT="${SERVER_PORT:-443}"
NODE_LABEL="${NODE_LABEL:-x420}"
SKIP_FIREWALL="${SKIP_FIREWALL:-1}"
SKIP_TUNE="${SKIP_TUNE:-0}"

usage() {
  cat <<'EOF'
x420 一键安装脚本

用途：
  在 Debian/Ubuntu VPS 上安装 Xray VLESS + REALITY + Vision over TCP/443。

用法：
  bash install.sh

可选环境变量：
  SERVER_ADDR=1.2.3.4
  SERVER_PORT=443
  REALITY_SERVER_NAME=www.microsoft.com
  REALITY_TARGET_DOMAIN=www.microsoft.com
  NODE_LABEL=x420
  SKIP_FIREWALL=1
  SKIP_TUNE=0
  TCP_TUNE_PROFILE=aggressive

说明：
  默认启用 TCP 调优；如需跳过可设置 SKIP_TUNE=1。
  默认跳过 UFW，避免系统缺少 iptables/nft 兼容路径时安装中断。

安装后会输出：
  - Shadowrocket vless:// 导入链接
  - /root/x420-shadowrocket.svg 二维码
  - /root/x420-client.env 客户端参数
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: 请使用 root 执行：sudo bash install.sh" >&2
    exit 1
  fi
}

die() {
  echo "error: $*" >&2
  exit 1
}

detect_server_addr() {
  local ip
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  [[ -n "$ip" ]] || die "无法检测 VPS 公网 IPv4，请手动设置 SERVER_ADDR。"
  printf '%s' "$ip"
}

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    return 0
  fi
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

main() {
  need_root
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y curl ca-certificates unzip openssl python3
  if [[ "$SKIP_FIREWALL" != "1" ]]; then
    apt-get install -y ufw
  fi

  install_xray

  curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"

  SERVER_ADDR="${SERVER_ADDR:-$(detect_server_addr)}"
  XRAY_UUID="$(xray uuid)"
  KEY_OUTPUT="$(xray x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/^PrivateKey:/ {print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/^Password \(PublicKey\):/ {print $2}')"
  REALITY_SHORT_ID="$(openssl rand -hex 8)"

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    echo "error: xray x25519 输出解析失败。" >&2
    printf '%s\n' "$KEY_OUTPUT" >&2
    exit 1
  fi

  export SERVER_ADDR SERVER_PORT XRAY_UUID
  export REALITY_SERVER_NAME="$SERVER_NAME"
  export REALITY_TARGET_DOMAIN="$TARGET_DOMAIN"
  export REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
  export NODE_LABEL

  "$SCRIPT_PATH" gen-server > /tmp/x420-xray-config.json
  install -d -m 0755 /usr/local/etc/xray
  install -m 600 /tmp/x420-xray-config.json /usr/local/etc/xray/config.json
  if getent passwd nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1; then
    chown nobody:nogroup /usr/local/etc/xray/config.json
  fi
  xray run -test -config /usr/local/etc/xray/config.json

  if [[ "$SKIP_TUNE" != "1" ]]; then
    "$SCRIPT_PATH" tune-server
  fi

  if [[ "$SKIP_FIREWALL" != "1" ]]; then
    "$SCRIPT_PATH" firewall-server
  fi

  "$SCRIPT_PATH" install-systemd
  systemctl daemon-reload
  systemctl enable xray >/dev/null
  systemctl reset-failed xray || true
  systemctl restart xray
  sleep 1
  systemctl is-active xray >/dev/null

  cat > /root/x420-client.env <<EOF
export SERVER_ADDR="${SERVER_ADDR}"
export SERVER_PORT="${SERVER_PORT}"
export XRAY_UUID="${XRAY_UUID}"
export REALITY_SERVER_NAME="${REALITY_SERVER_NAME}"
export REALITY_TARGET_DOMAIN="${REALITY_TARGET_DOMAIN}"
export REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
export REALITY_SHORT_ID="${REALITY_SHORT_ID}"
export NODE_LABEL="${NODE_LABEL}"
EOF
  chmod 600 /root/x420-client.env

  # shellcheck disable=SC1091
  . /root/x420-client.env
  "$SCRIPT_PATH" gen-shadowrocket-uri > /root/x420-shadowrocket.uri
  "$SCRIPT_PATH" gen-shadowrocket-qr /root/x420-shadowrocket.svg >/dev/null

  echo
  echo "== x420 安装完成 =="
  echo "服务状态: $(systemctl is-active xray)"
  echo "监听端口:"
  ss -tlpen | grep ":${SERVER_PORT} " || true
  echo
  echo "Shadowrocket URI:"
  cat /root/x420-shadowrocket.uri
  echo
  echo "二维码: /root/x420-shadowrocket.svg"
  echo "客户端参数: /root/x420-client.env"
}

main "$@"
