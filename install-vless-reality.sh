#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="$(basename "$0")"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_SHARE_DIR="/usr/local/share/xray"
XRAY_LOG_DIR="/var/log/xray"
CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
PARAM_FILE="${XRAY_CONFIG_DIR}/vless-reality.env"
SYSTEMD_UNIT="/etc/systemd/system/xray.service"
SYSCTL_FILE="/etc/sysctl.d/99-xray-vless-reality.conf"

PORT="443"
SNI="www.tesla.com"
DEST=""
CLIENT_ADDRESS=""
CLIENT_NAME="vless-reality"
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
FORCE="0"
NO_START="0"
TUNE="0"
TUNE_ONLY="0"
CLEAN="0"

usage() {
  cat <<USAGE
Usage:
  sudo ./${PROGRAM_NAME} [options]

Options:
  --sni DOMAIN          REALITY serverName. Default: ${SNI}
  --dest HOST:PORT      REALITY fallback destination. Default: <sni>:443
  --address ADDRESS     Address used in generated client URI. Default: auto-detected public IP
  --port PORT           Server listen port. Default: ${PORT}
  --name NAME           Client profile name. Default: ${CLIENT_NAME}
  --uuid UUID           Reuse an existing VLESS UUID instead of generating one
  --short-id HEX        Reuse an existing REALITY shortId. 0-16 hex chars, even length
  --private-key KEY     Reuse an existing REALITY private key
  --public-key KEY      Reuse an existing REALITY public key. Required if --private-key is used
  --force               Overwrite existing ${CONFIG_FILE}
  --no-start            Write files but do not enable or start xray
  --clean               Remove common old proxy stacks before installing
  --tune                Apply conservative TCP tuning for Xray/VLESS
  --tune-only           Apply TCP tuning only; do not install or change Xray config
  -h, --help            Show this help

Examples:
  sudo ./${PROGRAM_NAME}
  sudo ./${PROGRAM_NAME} --clean --tune
  sudo ./${PROGRAM_NAME} --tune
  sudo ./${PROGRAM_NAME} --tune-only
  sudo ./${PROGRAM_NAME} --sni www.cloudflare.com --address 203.0.113.10
  sudo ./${PROGRAM_NAME} --force --port 443 --name phone
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "[+] $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "This script must be run as root. Use sudo."
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --sni)
        SNI="${2:-}"
        shift 2
        ;;
      --dest)
        DEST="${2:-}"
        shift 2
        ;;
      --address)
        CLIENT_ADDRESS="${2:-}"
        shift 2
        ;;
      --port)
        PORT="${2:-}"
        shift 2
        ;;
      --name)
        CLIENT_NAME="${2:-}"
        shift 2
        ;;
      --uuid)
        UUID="${2:-}"
        shift 2
        ;;
      --short-id)
        SHORT_ID="${2:-}"
        shift 2
        ;;
      --private-key)
        PRIVATE_KEY="${2:-}"
        shift 2
        ;;
      --public-key)
        PUBLIC_KEY="${2:-}"
        shift 2
        ;;
      --force)
        FORCE="1"
        shift
        ;;
      --no-start)
        NO_START="1"
        shift
        ;;
      --clean)
        CLEAN="1"
        shift
        ;;
      --tune)
        TUNE="1"
        shift
        ;;
      --tune-only)
        TUNE="1"
        TUNE_ONLY="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

validate_args() {
  [[ -n "${SNI}" ]] || fail "--sni cannot be empty"
  [[ "${PORT}" =~ ^[0-9]+$ ]] || fail "--port must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || fail "--port must be between 1 and 65535"
  [[ "${DEST}" == *:* || -z "${DEST}" ]] || fail "--dest must use HOST:PORT format"

  if [[ -n "${SHORT_ID}" ]]; then
    [[ "${SHORT_ID}" =~ ^[0-9a-fA-F]*$ ]] || fail "--short-id must be hex"
    (( ${#SHORT_ID} <= 16 )) || fail "--short-id must be at most 16 hex chars"
    (( ${#SHORT_ID} % 2 == 0 )) || fail "--short-id length must be even"
  fi

  if [[ -n "${PRIVATE_KEY}" || -n "${PUBLIC_KEY}" ]]; then
    [[ -n "${PRIVATE_KEY}" ]] || fail "--private-key is required when --public-key is provided"
    [[ -n "${PUBLIC_KEY}" ]] || fail "--public-key is required when --private-key is provided"
  fi

  if [[ -z "${DEST}" ]]; then
    DEST="${SNI}:443"
  fi

  if [[ "${CLEAN}" == "1" && "${TUNE_ONLY}" == "1" ]]; then
    fail "--clean cannot be combined with --tune-only"
  fi
}

detect_platform() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    fail "Only Linux is supported."
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    fail "systemd is required."
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    fail "This script currently supports Debian/Ubuntu with apt-get."
  fi
}

detect_xray_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      echo "64"
      ;;
    aarch64|arm64)
      echo "arm64-v8a"
      ;;
    armv7l|armv7*)
      echo "arm32-v7a"
      ;;
    armv6l)
      echo "arm32-v6"
      ;;
    i386|i686)
      echo "32"
      ;;
    *)
      fail "Unsupported CPU architecture: $(uname -m)"
      ;;
  esac
}

install_dependencies() {
  info "Installing dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip openssl iproute2
}

download_and_install_xray() {
  local arch
  local tmp_dir
  local url

  arch="$(detect_xray_arch)"
  tmp_dir="$(mktemp -d)"
  url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"

  info "Downloading xray-core: ${url}"
  curl -fL --retry 3 --connect-timeout 15 -o "${tmp_dir}/xray.zip" "${url}"
  unzip -q "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"

  install -d -m 0755 "$(dirname "${XRAY_BIN}")" "${XRAY_SHARE_DIR}"
  install -m 0755 "${tmp_dir}/xray/xray" "${XRAY_BIN}"

  if [[ -f "${tmp_dir}/xray/geoip.dat" ]]; then
    install -m 0644 "${tmp_dir}/xray/geoip.dat" "${XRAY_SHARE_DIR}/geoip.dat"
  fi

  if [[ -f "${tmp_dir}/xray/geosite.dat" ]]; then
    install -m 0644 "${tmp_dir}/xray/geosite.dat" "${XRAY_SHARE_DIR}/geosite.dat"
  fi

  rm -rf "${tmp_dir}"
}

create_user_and_dirs() {
  if ! id xray >/dev/null 2>&1; then
    info "Creating xray system user"
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
  fi

  install -d -m 0755 "${XRAY_CONFIG_DIR}" "${XRAY_LOG_DIR}"
  chown -R xray:xray "${XRAY_LOG_DIR}"
}

clean_existing_proxy_stack() {
  local services
  local svc

  info "Cleaning common old proxy stacks"

  services=(
    xray
    "xray@default"
    v2ray
    sing-box
    trojan-go
    hysteria
    hysteria-server
    naiveproxy
    caddy
    nginx
  )

  for svc in "${services[@]}"; do
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  done

  apt-get purge -y nginx nginx-common sing-box caddy 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true

  rm -f /usr/local/bin/trojan-go
  rm -f /usr/local/bin/xray
  rm -f /usr/local/bin/v2ray
  rm -f /usr/local/bin/sing-box
  rm -f /usr/local/bin/hysteria
  rm -f /usr/local/bin/naiveproxy
  rm -f /usr/local/bin/caddy

  rm -f /etc/systemd/system/trojan-go.service
  rm -f /etc/systemd/system/xray.service
  rm -f /etc/systemd/system/xray@.service
  rm -f /etc/systemd/system/v2ray.service
  rm -f /etc/systemd/system/sing-box.service
  rm -f /etc/systemd/system/hysteria.service
  rm -f /etc/systemd/system/hysteria-server.service
  rm -f /etc/systemd/system/naiveproxy.service
  rm -f /etc/systemd/system/caddy.service

  rm -rf /etc/trojan-go
  rm -rf /etc/xray
  rm -rf /etc/v2ray
  rm -rf /etc/sing-box
  rm -rf /etc/hysteria
  rm -rf /etc/naiveproxy
  rm -rf /etc/caddy
  rm -rf /etc/nginx
  rm -rf /usr/local/etc/xray
  rm -rf /usr/local/etc/v2ray
  rm -rf /usr/local/etc/sing-box
  rm -rf /usr/local/share/xray
  rm -rf /var/log/xray
  rm -rf /var/log/trojan-go
  rm -rf /var/log/v2ray
  rm -rf /var/log/sing-box
  rm -rf /var/log/hysteria
  rm -rf /var/log/nginx
  rm -rf /var/lib/nginx
  rm -rf /var/cache/nginx

  systemctl daemon-reload
  systemctl reset-failed
}

generate_credentials() {
  local keys

  if [[ -z "${UUID}" ]]; then
    UUID="$("${XRAY_BIN}" uuid)"
  fi

  if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
    keys="$("${XRAY_BIN}" x25519)"
    PRIVATE_KEY="$(awk -F': ' '/PrivateKey|Private key/ {print $2; exit}' <<<"${keys}")"
    PUBLIC_KEY="$(awk -F': ' '/PublicKey|Public key/ {print $2; exit}' <<<"${keys}")"
  fi

  [[ -n "${PRIVATE_KEY}" ]] || fail "Could not parse REALITY private key from xray x25519 output"
  [[ -n "${PUBLIC_KEY}" ]] || fail "Could not parse REALITY public key from xray x25519 output"

  if [[ -z "${SHORT_ID}" ]]; then
    SHORT_ID="$(openssl rand -hex 8)"
  fi
}

detect_client_address() {
  if [[ -n "${CLIENT_ADDRESS}" ]]; then
    return
  fi

  CLIENT_ADDRESS="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  if [[ -z "${CLIENT_ADDRESS}" ]]; then
    CLIENT_ADDRESS="$(curl -fsS --max-time 10 https://ifconfig.me || true)"
  fi

  [[ -n "${CLIENT_ADDRESS}" ]] || fail "Could not detect public IP. Pass --address manually."
}

ensure_no_config_conflict() {
  if [[ -f "${CONFIG_FILE}" && "${FORCE}" != "1" ]]; then
    fail "${CONFIG_FILE} already exists. Re-run with --force to overwrite."
  fi
}

backup_existing_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    local backup
    backup="${CONFIG_FILE}.$(date +%Y%m%d%H%M%S).bak"
    info "Backing up existing config to ${backup}"
    cp -a "${CONFIG_FILE}" "${backup}"
  fi
}

write_xray_config() {
  info "Writing ${CONFIG_FILE}"
  cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
  chmod 0644 "${CONFIG_FILE}"
}

write_param_file() {
  cat > "${PARAM_FILE}" <<EOF
UUID=${UUID}
PORT=${PORT}
CLIENT_ADDRESS=${CLIENT_ADDRESS}
SNI=${SNI}
DEST=${DEST}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
FLOW=xtls-rprx-vision
FINGERPRINT=chrome
EOF
  chmod 0600 "${PARAM_FILE}"
}

write_systemd_unit() {
  info "Writing ${SYSTEMD_UNIT}"
  cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

validate_xray_config() {
  info "Validating xray config"
  "${XRAY_BIN}" run -test -config "${CONFIG_FILE}"
}

apply_tcp_tuning() {
  info "Applying TCP tuning to ${SYSCTL_FILE}"

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
  fi

  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    fail "BBR is not available on this kernel"
  fi

  cat > "${SYSCTL_FILE}" <<EOF
# TCP tuning for Xray VLESS Reality on a single VPS.
# Conservative values for Debian/Ubuntu kernels with BBR support.

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 250000

net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

net.ipv4.ip_local_port_range = 10000 65000

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_fastopen = 3
EOF

  sysctl -p "${SYSCTL_FILE}"
}

open_firewall_if_active() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi '^Status: active'; then
    info "Allowing ${PORT}/tcp through ufw"
    ufw allow "${PORT}/tcp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    info "Allowing ${PORT}/tcp through firewalld"
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
  fi
}

start_service() {
  if [[ "${NO_START}" == "1" ]]; then
    info "--no-start set; skipping service start"
    return
  fi

  info "Starting xray"
  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
  systemctl --no-pager --full status xray
}

print_tuning_output() {
  if [[ "${TUNE}" != "1" ]]; then
    return
  fi

  cat <<EOF

==================== TCP TUNING ====================
Sysctl file:
${SYSCTL_FILE}

Current values:
$(sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.ip_local_port_range net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes net.ipv4.tcp_fastopen 2>/dev/null)
====================================================
EOF
}

print_client_output() {
  local uri
  local uri_host

  uri_host="${CLIENT_ADDRESS}"
  if [[ "${uri_host}" == *:* && "${uri_host}" != \[*\] ]]; then
    uri_host="[${uri_host}]"
  fi

  uri="vless://${UUID}@${uri_host}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&spx=%2F#${CLIENT_NAME}"

  cat <<EOF

==================== VLESS REALITY CLIENT ====================
Address:     ${CLIENT_ADDRESS}
Port:        ${PORT}
UUID:        ${UUID}
Flow:        xtls-rprx-vision
Security:    reality
Network:     tcp
SNI:         ${SNI}
Fingerprint: chrome
PublicKey:   ${PUBLIC_KEY}
ShortId:     ${SHORT_ID}
SpiderX:     /

URI:
${uri}

Server config:
${CONFIG_FILE}

Saved parameters:
${PARAM_FILE}
===============================================================
EOF
}

main() {
  parse_args "$@"
  validate_args
  require_root
  detect_platform

  if [[ "${TUNE_ONLY}" == "1" ]]; then
    apply_tcp_tuning
    print_tuning_output
    exit 0
  fi

  if [[ "${CLEAN}" == "1" ]]; then
    clean_existing_proxy_stack
  fi

  ensure_no_config_conflict
  install_dependencies
  download_and_install_xray
  create_user_and_dirs
  generate_credentials
  detect_client_address
  backup_existing_config
  write_xray_config
  write_param_file
  write_systemd_unit
  validate_xray_config
  if [[ "${TUNE}" == "1" ]]; then
    apply_tcp_tuning
  fi
  open_firewall_if_active
  start_service
  print_tuning_output
  print_client_output
}

main "$@"
