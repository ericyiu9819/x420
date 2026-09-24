#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
SECRETS_FILE="/usr/local/etc/xray/vless-no-redundant.env"
SHARE_FILE="/usr/local/etc/xray/share-link.txt"
KEEP_SECRETS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-secrets) KEEP_SECRETS=1; shift ;;
    -h|--help)
      echo "用法: sudo $0 [--keep-secrets]"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

echo "==> 停止并移除 Xray（保留/删除密钥由参数决定）"
bash -c "$(curl -L "$INSTALL_URL")" @ remove || true

if [[ "$KEEP_SECRETS" -eq 0 ]]; then
  rm -f "$SECRETS_FILE" "$SHARE_FILE"
  echo "已删除 $SECRETS_FILE $SHARE_FILE"
else
  echo "已保留密钥文件"
fi

echo "卸载流程结束"
