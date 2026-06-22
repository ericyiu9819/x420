#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
# shellcheck disable=SC1090
source "${ROOT_DIR}/${ENV_FILE}"
set +a

echo "== TCP HTTPS fallback =="
curl -I --resolve "${DOMAIN}:443:${SERVER_IP}" "https://${DOMAIN}/" --max-time 10

echo
echo "== Local rendered config files =="
test -s "${ROOT_DIR}/build/xray-server.json" && echo "xray-server.json ok"
test -s "${ROOT_DIR}/build/client-sing-box.json" && echo "client-sing-box.json ok"

echo
echo "== TCP proxy check hint =="
echo "Use a sing-box client with build/client-sing-box.json to verify vless-tcp."
