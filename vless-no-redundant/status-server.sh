#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
SECRETS_FILE="/usr/local/etc/xray/vless-no-redundant.env"
SHARE_FILE="/usr/local/etc/xray/share-link.txt"

echo "==> xray 服务状态"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --no-pager --full status xray | sed -n '1,20p' || true
else
  echo "无 systemctl"
fi

echo
echo "==> 配置校验"
if [[ -f "$XRAY_CONFIG" ]] && command -v xray >/dev/null 2>&1; then
  xray run -test -c "$XRAY_CONFIG" || true
else
  echo "缺少 $XRAY_CONFIG 或 xray"
fi

echo
if [[ -f "$SECRETS_FILE" ]]; then
  echo "==> 密钥文件: $SECRETS_FILE"
  # do not dump private key; show non-secret fields only
  grep -E '^(UUID|SHORT_ID|SNI|DEST|PORT|SERVER_ADDR|NETWORK|FINGERPRINT|FLOW|MUX)=' "$SECRETS_FILE" || true
else
  echo "未找到密钥文件"
fi

echo
if [[ -f "$SHARE_FILE" ]]; then
  echo "==> Share link:"
  cat "$SHARE_FILE"
fi

show_bbr_status
