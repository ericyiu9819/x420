#!/usr/bin/env bash
# Offline/local secret + config generation (no install). Useful before上传到 VPS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

PORT="${PORT:-$DEFAULT_PORT}"
SNI="${SNI:-$DEFAULT_SNI}"
DEST="${DEST:-$DEFAULT_DEST}"
NETWORK="${NETWORK:-$DEFAULT_NETWORK}"
FINGERPRINT="${FINGERPRINT:-$DEFAULT_FP}"
SERVER_ADDR="${SERVER_ADDR:-YOUR_SERVER_IP}"
OUT_DIR="$SCRIPT_DIR/generated"

usage() {
  cat <<EOF
用法: $0 [--server <host>] [--port 443] [--sni name] [--dest host:port] [--network tcp|raw] [--out-dir DIR]

在本机生成:
  secrets.env / server.json / client.json / share-link.txt
不安装系统服务。需要本机已有 xray 命令；若没有，则用 python 生成 UUID，并提示稍后在服务器上生成 Reality 密钥。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER_ADDR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

need_cmd python3
mkdir -p "$OUT_DIR"

if command -v xray >/dev/null 2>&1; then
  UUID="$(xray uuid)"
  parse_x25519 "$(xray x25519)"
else
  echo "WARN: 未找到 xray，使用 python 生成 UUID；Reality 密钥将用 openssl 近似流程提示" >&2
  UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  die "请先安装 xray（或到 VPS 上运行 install-server.sh）。Reality 密钥必须用 xray x25519 生成。"
fi
SHORT_ID="$(gen_short_id)"

SECRETS_FILE="$OUT_DIR/vless-no-redundant.env"
render_server_json "$UUID" "$PORT" "$SNI" "$DEST" "$PRIVATE_KEY" "$SHORT_ID" "$NETWORK" >"$OUT_DIR/server.json"
render_client_json "$SERVER_ADDR" "$PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$NETWORK" "$FINGERPRINT" "10808" >"$OUT_DIR/client.json"
write_secrets_env "$SECRETS_FILE"
build_share_link "$SERVER_ADDR" "vless-nr" | tee "$OUT_DIR/share-link.txt" >/dev/null
chmod 600 "$OUT_DIR/server.json" "$OUT_DIR/client.json" "$OUT_DIR/share-link.txt"

echo "已生成到 $OUT_DIR"
echo "Share link:"
cat "$OUT_DIR/share-link.txt"
