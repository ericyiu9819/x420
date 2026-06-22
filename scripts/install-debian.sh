#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root on the VPS." >&2
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  ENV_FILE="$(cd "$(dirname "${ENV_FILE}")" && pwd)/$(basename "${ENV_FILE}")"
else
  ENV_FILE="${ROOT_DIR}/${ENV_FILE}"
fi

"${ROOT_DIR}/scripts/render-configs.sh" "${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

apt-get update
apt-get install -y curl ca-certificates gnupg lsb-release unzip tar perl caddy

if ! command -v xray >/dev/null 2>&1; then
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
fi

install -d -m 0755 /usr/local/etc/xray /etc/caddy "${SITE_ROOT}"
install -m 0644 "${BUILD_DIR}/xray-server.json" /usr/local/etc/xray/config.json
install -m 0644 "${BUILD_DIR}/Caddyfile" /etc/caddy/Caddyfile
install -m 0644 "${BUILD_DIR}/index.html" "${SITE_ROOT}/index.html"

cat > /etc/sysctl.d/99-rescue-gateway.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF
sysctl --system >/dev/null

if [[ ! -f "${TLS_CERT}" || ! -f "${TLS_KEY}" ]]; then
  cat >&2 <<EOF
TLS files are not present:
  ${TLS_CERT}
  ${TLS_KEY}

Put a valid certificate/key there, or use Caddy/ACME to obtain one and update .env.
EOF
  exit 1
fi

systemctl enable caddy
systemctl restart caddy

systemctl enable xray
systemctl restart xray

if systemctl list-unit-files hysteria-server.service >/dev/null 2>&1; then
  systemctl disable --now hysteria-server || true
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow 443/tcp || true
fi

echo "Installed. Client config: ${BUILD_DIR}/client-sing-box.json"
