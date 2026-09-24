#!/usr/bin/env bash
# Generate client.json + share link from secrets.env
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

SECRETS=""
SERVER=""
OUT="./client.json"
MIXED_PORT="10808"
LINK_OUT=""

usage() {
  cat <<EOF
用法: $0 --secrets <file> --server <ip-or-domain> [options]

选项:
  --secrets <file>     install-server 生成的 vless-no-redundant.env
  --server <host>      服务器地址
  --out <path>         客户端 JSON 输出路径，默认 ./client.json
  --mixed-port <port>  本地 mixed 入站端口，默认 10808
  --link-out <path>    同时写出分享链接文件
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --secrets) SECRETS="$2"; shift 2 ;;
    --server) SERVER="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mixed-port) MIXED_PORT="$2"; shift 2 ;;
    --link-out) LINK_OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$SECRETS" ]] || die "必须提供 --secrets"
[[ -n "$SERVER" ]] || die "必须提供 --server"
need_cmd python3

load_secrets_env "$SECRETS"
NETWORK="${NETWORK:-tcp}"
FINGERPRINT="${FINGERPRINT:-chrome}"

mkdir -p "$(dirname "$OUT")"
render_client_json "$SERVER" "$PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$NETWORK" "$FINGERPRINT" "$MIXED_PORT" >"$OUT"
chmod 600 "$OUT"

LINK="$(build_share_link "$SERVER" "vless-nr")"
if [[ -n "$LINK_OUT" ]]; then
  printf '%s\n' "$LINK" >"$LINK_OUT"
  chmod 600 "$LINK_OUT"
fi

cat <<EOF
已生成客户端配置: $OUT
约束确认:
  - protocol=vless
  - flow=xtls-rprx-vision
  - mux.enabled=false
  - routing: private/cn → direct，其余 → proxy
  - 单出口: $SERVER:$PORT

Share link:
$LINK

本地测试（示例）:
  xray run -c $OUT
  curl -x socks5h://127.0.0.1:${MIXED_PORT} https://www.google.com -I
EOF
