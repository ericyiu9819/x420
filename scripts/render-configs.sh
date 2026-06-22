#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  echo "Copy server.env.example to .env and edit it first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required_vars=(
  DOMAIN SERVER_IP CONTACT_EMAIL TLS_CERT TLS_KEY
  VLESS_UUID
  FALLBACK_LISTEN SITE_ROOT CLIENT_MIXED_PORT
)

for name in "${required_vars[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 1
  fi
done

mkdir -p "${BUILD_DIR}"

render() {
  local src="$1"
  local dst="$2"
  perl -pe 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : $&/ge' \
    < "${ROOT_DIR}/${src}" > "${BUILD_DIR}/${dst}"
}

render templates/xray-server.json.tmpl xray-server.json
render templates/Caddyfile.tmpl Caddyfile
render templates/client-sing-box.json.tmpl client-sing-box.json
render templates/index.html.tmpl index.html

cat > "${BUILD_DIR}/client-links.txt" <<EOF
vless://${VLESS_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp#vless-tcp
EOF

echo "Rendered configs into ${BUILD_DIR}"
