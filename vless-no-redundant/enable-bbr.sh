#!/usr/bin/env bash
# Enable BBR (+ fq) for the existing TCP path. Does not add proxy connections.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF
用法: sudo $0

在本机启用 BBR + fq，并写入 /etc/sysctl.d/99-vless-nr-bbr.conf 持久化。
这是传输层优化，不会新增 VLESS 连接或跳数。
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

enable_bbr
show_bbr_status
