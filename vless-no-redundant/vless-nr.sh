#!/usr/bin/env bash
# Unified entrypoint for VLESS no-redundant scripts
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
VLESS 无冗余连接脚本入口

用法:
  vless-nr.sh install-server [args...]
  vless-nr.sh gen-client [args...]
  vless-nr.sh gen-secrets [args...]
  vless-nr.sh status
  vless-nr.sh enable-bbr
  vless-nr.sh uninstall-server [args...]

示例:
  sudo ./vless-nr.sh install-server --port 443
  ./vless-nr.sh gen-client --secrets /usr/local/etc/xray/vless-no-redundant.env --server 1.2.3.4 --out ./client.json
EOF
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 1; }
shift || true

case "$cmd" in
  install-server|install) exec "$SCRIPT_DIR/install-server.sh" "$@" ;;
  gen-client|client) exec "$SCRIPT_DIR/gen-client.sh" "$@" ;;
  gen-secrets|secrets) exec "$SCRIPT_DIR/gen-secrets.sh" "$@" ;;
  status) exec "$SCRIPT_DIR/status-server.sh" "$@" ;;
  enable-bbr|bbr) exec "$SCRIPT_DIR/enable-bbr.sh" "$@" ;;
  uninstall-server|uninstall) exec "$SCRIPT_DIR/uninstall-server.sh" "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "未知命令: $cmd" >&2; usage; exit 1 ;;
esac

