#!/usr/bin/env bash
# Install Xray + VLESS/RAW|TCP + REALITY + Vision (mux off, single exit)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

PORT="${PORT:-$DEFAULT_PORT}"
SNI="${SNI:-$DEFAULT_SNI}"
DEST="${DEST:-$DEFAULT_DEST}"
NETWORK="${NETWORK:-$DEFAULT_NETWORK}"
FINGERPRINT="${FINGERPRINT:-$DEFAULT_FP}"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_CONFIG_DIR/config.json"
SECRETS_FILE="$XRAY_CONFIG_DIR/vless-no-redundant.env"
SHARE_FILE="$XRAY_CONFIG_DIR/share-link.txt"
INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

usage() {
  cat <<EOF
用法: sudo $0 [options]

选项:
  --port <port>          监听端口，默认 443
  --sni <name>           REALITY serverNames / 客户端 sni，默认 $DEFAULT_SNI
  --dest <host:port>     REALITY dest，默认 $DEFAULT_DEST
  --network <tcp|raw>    传输名，默认 tcp（客户端兼容更好）
  --server-addr <host>   写入分享链接的地址；默认自动探测公网 IPv4
  --reuse-secrets        若已有 $SECRETS_FILE 则复用，不轮换密钥
  --skip-bbr             跳过 BBR/fq 启用
  -h, --help             显示帮助
EOF
}

REUSE_SECRETS=0
SKIP_BBR=0
SERVER_ADDR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --server-addr) SERVER_ADDR="$2"; shift 2 ;;
    --reuse-secrets) REUSE_SECRETS=1; shift ;;
    --skip-bbr) SKIP_BBR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ "$NETWORK" == "tcp" || "$NETWORK" == "raw" ]] || die "--network 只能是 tcp 或 raw"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "端口无效: $PORT"

require_root
need_cmd curl
need_cmd python3

echo "==> 安装 / 升级 Xray-core"
bash -c "$(curl -L "$INSTALL_URL")" @ install

need_cmd xray
mkdir -p "$XRAY_CONFIG_DIR"

if [[ "$REUSE_SECRETS" -eq 1 && -f "$SECRETS_FILE" ]]; then
  echo "==> 复用已有密钥: $SECRETS_FILE"
  load_secrets_env "$SECRETS_FILE"
  SNI="${SNI}"
  DEST="${DEST:-$DEFAULT_DEST}"
  PORT="${PORT}"
  NETWORK="${NETWORK}"
  FINGERPRINT="${FINGERPRINT}"
else
  echo "==> 生成 UUID / Reality 密钥 / shortId"
  UUID="$(xray uuid)"
  X25519_RAW="$(xray x25519)"
  parse_x25519 "$X25519_RAW"
  SHORT_ID="$(gen_short_id)"
fi

if [[ -z "${SERVER_ADDR}" ]]; then
  SERVER_ADDR="$(detect_public_ip || true)"
  if [[ -z "${SERVER_ADDR}" ]]; then
    echo "WARN: 无法自动探测公网 IP，分享链接里的地址请稍后手工填写" >&2
    SERVER_ADDR="YOUR_SERVER_IP"
  fi
fi

echo "==> 写入服务端配置: $XRAY_CONFIG"
render_server_json "$UUID" "$PORT" "$SNI" "$DEST" "$PRIVATE_KEY" "$SHORT_ID" "$NETWORK" >"$XRAY_CONFIG"
chmod 644 "$XRAY_CONFIG"

echo "==> 校验配置"
if ! xray run -test -c "$XRAY_CONFIG"; then
  if [[ "$NETWORK" == "tcp" ]]; then
    echo "==> tcp 校验失败，回退 network=raw 再试"
    NETWORK="raw"
    render_server_json "$UUID" "$PORT" "$SNI" "$DEST" "$PRIVATE_KEY" "$SHORT_ID" "$NETWORK" >"$XRAY_CONFIG"
    xray run -test -c "$XRAY_CONFIG"
  else
    die "配置校验失败"
  fi
fi

write_secrets_env "$SECRETS_FILE"
build_share_link "$SERVER_ADDR" "vless-nr" | tee "$SHARE_FILE" >/dev/null
chmod 600 "$SHARE_FILE"

# optional firewall helpers
open_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${PORT}/tcp" || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd --reload || true
  fi
}
echo "==> 尝试放行防火墙端口 ${PORT}/tcp"
open_port

if [[ "$SKIP_BBR" -eq 0 ]]; then
  echo "==> 启用 BBR + fq（同路径传输优化，不新增连接）"
  enable_bbr || echo "WARN: BBR 未启用，继续安装" >&2
else
  echo "==> 已指定 --skip-bbr，跳过 BBR"
fi

echo "==> 启动 xray"
systemctl enable xray >/dev/null
systemctl restart xray
systemctl --no-pager --full status xray | sed -n '1,15p'

CLIENT_OUT="$SCRIPT_DIR/generated/client.json"
mkdir -p "$SCRIPT_DIR/generated"
render_client_json "$SERVER_ADDR" "$PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$NETWORK" "$FINGERPRINT" "10808" >"$CLIENT_OUT"
chmod 600 "$CLIENT_OUT"

cat <<EOF

================ 部署完成（无冗余连接方案） ================
协议栈 : VLESS + ${NETWORK} + REALITY + Vision
mux    : 关闭
出口   : 单节点 freedom
分流   : 客户端 geoip:cn / geosite:cn / private → direct
BBR    : 默认启用（可用 --skip-bbr 关闭）

密钥文件 : $SECRETS_FILE
服务配置 : $XRAY_CONFIG
分享链接 : $SHARE_FILE
本机示例客户端配置: $CLIENT_OUT

Share link:
$(cat "$SHARE_FILE")

生成/更新客户端（可在任意机器）:
  $SCRIPT_DIR/gen-client.sh --secrets $SECRETS_FILE --server $SERVER_ADDR --out ./client.json

验收:
  1) systemctl is-active xray
  2) 客户端 mux.enabled 必须为 false
  3) 国内站直连，不进隧道
==========================================================
EOF
