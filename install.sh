#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/ericyiu9819/x420/main}"
SCRIPT_URL="${SCRIPT_URL:-${REPO_RAW_BASE}/tcp-reality-single.sh}"
SCRIPT_PATH="/usr/local/bin/tcp-reality-single"

usage() {
  cat <<'EOF'
x420 lean installer

Usage:
  bash install.sh

Common env:
  SERVER_ADDR=1.2.3.4
  SERVER_PORT=443
  REALITY_SERVER_NAME=www.tesla.com
  REALITY_TARGET_DOMAIN=www.tesla.com
  NODE_LABEL=x420
  TUNE_PROFILE=balanced
  SKIP_TUNE=0
  XRAY_SOCKOPT=1

This wrapper only downloads tcp-reality-single.sh and runs:
  /usr/local/bin/tcp-reality-single install
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "error: run as root" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  echo "error: missing curl" >&2
  exit 1
}

curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
exec "$SCRIPT_PATH" install "$@"
