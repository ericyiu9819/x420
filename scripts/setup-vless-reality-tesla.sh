#!/usr/bin/env bash
set -Eeuo pipefail

# VLESS + RAW(TCP) + REALITY + 系统调优
# 不需要自有域名或 TLS 证书
#
# 运行：
# sudo bash setup-vless-reality-tesla.sh
#
# 可选：
# SERVER_IP=38.54.82.45 sudo bash setup-vless-reality-tesla.sh

TARGET_DOMAIN="www.tesla.com"
TARGET_PORT="443"
TARGET="${TARGET_DOMAIN}:${TARGET_PORT}"
NODE_NAME="reality-tesla"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
SYSCTL_CONFIG="/etc/sysctl.d/99-vless-reality.conf"
SYSTEMD_OVERRIDE="/etc/systemd/system/xray.service.d/99-performance.conf"

[[ $EUID -eq 0 ]] || {
  echo "请以 root 或 sudo 运行。"
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates openssl

# 安装 Xray。
if [[ ! -x "$XRAY_BIN" ]]; then
  INSTALLER="$(mktemp)"
  trap 'rm -f "$INSTALLER"' EXIT

  curl -fsSL \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    -o "$INSTALLER"

  bash "$INSTALLER" install
fi

# ---------- 系统调优 ----------
# BBR 可用时启用；不支持时保留系统默认拥塞控制算法。
modprobe tcp_bbr 2>/dev/null || true

if sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -qx "bbr"; then
  CONGESTION_CONTROL="bbr"
else
  CONGESTION_CONTROL="$(sysctl -n net.ipv4.tcp_congestion_control)"
fi

cat > "$SYSCTL_CONFIG" <<EOF
# 面向高并发 TCP 转发的保守调优
fs.file-max = 1048576

# 连接建立与排队
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3

# TCP 缓冲区上限
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 队列与拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CONGESTION_CONTROL}

# 扩大出站临时端口范围
net.ipv4.ip_local_port_range = 10240 65535
EOF

sysctl -p "$SYSCTL_CONFIG"

# 确保 Xray 服务具有充足文件句柄上限。
install -d -m 755 /etc/systemd/system/xray.service.d

cat > "$SYSTEMD_OVERRIDE" <<'EOF'
[Service]
LimitNOFILE=1048576
TasksMax=infinity
EOF

systemctl daemon-reload

# ---------- REALITY 目标校验 ----------
timeout 15 openssl s_client \
  -connect "$TARGET" \
  -servername "$TARGET_DOMAIN" \
  -verify_return_error </dev/null 2>&1 |
  grep -q "Verify return code: 0 (ok)" || {
    echo "无法验证 ${TARGET} 的 TLS 连接，未改动 Xray 配置。"
    exit 1
  }

SERVER_IP="${SERVER_IP:-$(curl -4fsSL --max-time 10 https://api.ipify.org)}"
[[ -n "$SERVER_IP" ]] || {
  echo "无法获取服务器公网 IPv4。"
  exit 1
}

UUID="$("$XRAY_BIN" uuid)"
KEYS="$("$XRAY_BIN" x25519)"
PRIVATE_KEY="$(awk -F ': ' '/^PrivateKey:/ {print $2}' <<<"$KEYS")"
PUBLIC_KEY="$(awk -F ': ' '/^Password / {print $2}' <<<"$KEYS")"
SHORT_ID="$(openssl rand -hex 8)"

[[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || {
  echo "生成 UUID 或 REALITY 密钥失败。"
  exit 1
}

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 443/tcp
fi

TEMP_CONFIG="$(mktemp)"
trap 'rm -f "$TEMP_CONFIG"' EXIT

cat > "$TEMP_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "email": "default-user",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$TARGET",
          "xver": 0,
          "serverNames": [
            "$TARGET_DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

"$XRAY_BIN" run -test -config "$TEMP_CONFIG"
install -m 644 "$TEMP_CONFIG" "$XRAY_CONFIG"

systemctl enable xray
systemctl restart xray
systemctl is-active --quiet xray

echo
echo "部署完成。"
echo "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"
echo "队列规则：$(sysctl -n net.core.default_qdisc)"
echo "Xray 状态：$(systemctl is-active xray)"
echo
echo "客户端导入链接："
echo "vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${TARGET_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}"
