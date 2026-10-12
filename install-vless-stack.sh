#!/usr/bin/env bash
# VLESS + TCP:443 + REALITY + xtls-rprx-vision
# 内核: BBR + fq + 小缓冲 + MTU探测 + 空闲不慢启动
# 出网: IPv4 only；Xray 直听 443，root 运行，无反代/Mux
#
# root 执行:
#   bash install-vless-stack.sh
#   DEST=www.apple.com SNI=www.apple.com bash install-vless-stack.sh
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请用 root 运行" >&2
  exit 1
fi

DEST="${DEST:-www.apple.com}"
SNI="${SNI:-$DEST}"
PORT="${PORT:-443}"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
CRED_FILE="/root/vless-reality-credentials.txt"

echo "==> 依赖"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl ca-certificates openssl ethtool iproute2
fi

echo "==> 内核网络栈"
cat >/etc/sysctl.d/99-vless-stack.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rmem=4096 131072 6291456
net.ipv4.tcp_wmem=4096 16384 4194304
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.ip_forward=0
EOF
sysctl --system >/dev/null

# 主网卡卸载：少拷贝。失败则忽略。
IFACE="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
if [[ -n "${IFACE:-}" ]] && command -v ethtool >/dev/null 2>&1; then
  ethtool -K "$IFACE" gro on gso on tso on 2>/dev/null || true
  echo "nic=$IFACE offload=gro/gso/tso"
fi

echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"

echo "==> 校验 REALITY dest"
if ! openssl s_client -connect "${DEST}:443" -servername "${SNI}" </dev/null 2>/dev/null | grep -q "Verify return code"; then
  echo "无法 TLS 到 ${DEST}:443 (SNI=${SNI})，换 DEST/SNI" >&2
  exit 1
fi

echo "==> 安装 Xray (user=root)"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

UUID="$(xray uuid)"
X25519_OUT="$(xray x25519)"
PRIVATE_KEY="$(printf '%s\n' "$X25519_OUT" | awk -F': *' 'BEGIN{IGNORECASE=1} /Private/{print $2; exit}')"
PUBLIC_KEY="$(printf '%s\n' "$X25519_OUT" | awk -F': *' 'BEGIN{IGNORECASE=1} /Public|Password/{print $2; exit}')"
SHORT_ID="$(openssl rand -hex 8)"
PRIVATE_KEY="$(echo "$PRIVATE_KEY" | tr -d '[:space:]')"
PUBLIC_KEY="$(echo "$PUBLIC_KEY" | tr -d '[:space:]')"

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo "x25519 解析失败: $X25519_OUT" >&2
  exit 1
fi

SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
[[ -z "$SERVER_IP" ]] && SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "==> 写入 ${XRAY_CONFIG}"
install -d -m 755 /usr/local/etc/xray
cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

xray run -test -config "$XRAY_CONFIG"

echo "==> 防火墙"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 22/tcp || true
  ufw allow "${PORT}/tcp" || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=ssh || true
  firewall-cmd --permanent --add-port="${PORT}/tcp"
  firewall-cmd --reload
fi

systemctl enable xray
systemctl restart xray
sleep 1
systemctl --no-pager --full status xray | head -n 16
ss -lntp | grep -E "[:.]${PORT} " || true

SHARE="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#vless-reality"

umask 077
cat >"$CRED_FILE" <<EOF
protocol=vless
address=${SERVER_IP}
port=${PORT}
uuid=${UUID}
flow=xtls-rprx-vision
network=tcp
security=reality
sni=${SNI}
dest=${DEST}:443
fingerprint=chrome
publicKey=${PUBLIC_KEY}
privateKey=${PRIVATE_KEY}
shortId=${SHORT_ID}
cc=$(sysctl -n net.ipv4.tcp_congestion_control)
qdisc=$(sysctl -n net.core.default_qdisc)
share=${SHARE}
EOF

echo
echo "======== 完成 ========"
echo "凭证: ${CRED_FILE}"
echo "Shadowrocket 导入:"
echo "${SHARE}"
echo "云安全组放行 TCP ${PORT}"
echo "客户端: 国内直连，关 Mux"
