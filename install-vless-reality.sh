#!/usr/bin/env bash
set -euo pipefail

# Single VPS shortest-path Xray setup:
# client -> VPS:PORT -> internet
#
# Defaults can be overridden:
#   PORT=443 SERVER_ADDR=your.domain.com SERVER_NAME=www.tesla.com TARGET=www.tesla.com:443 bash install-vless-reality.sh

PORT="${PORT:-443}"
SERVER_NAME="${SERVER_NAME:-www.tesla.com}"
TARGET="${TARGET:-${SERVER_NAME}:443}"
EMAIL="${EMAIL:-main@vless-reality}"
ENABLE_NET_TUNING="${ENABLE_NET_TUNING:-1}"
TCP_BUFFER_MAX="${TCP_BUFFER_MAX:-67108864}"
XRAY_NOFILE_LIMIT="${XRAY_NOFILE_LIMIT:-1048576}"
CONFIG_PATH="/usr/local/etc/xray/config.json"
CLIENT_INFO_PATH="/root/vless-reality-client.txt"
SYSCTL_TUNE_PATH="/etc/sysctl.d/99-xray-vless-reality-net.conf"
MODULES_LOAD_PATH="/etc/modules-load.d/99-xray-vless-reality.conf"
XRAY_SERVICE_OVERRIDE_DIR="/etc/systemd/system/xray.service.d"
XRAY_SERVICE_OVERRIDE_PATH="${XRAY_SERVICE_OVERRIDE_DIR}/10-limits.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "This script requires a systemd-based Linux VPS."
  exit 1
fi

if ! [[ "${TCP_BUFFER_MAX}" =~ ^[0-9]+$ ]]; then
  echo "TCP_BUFFER_MAX must be a positive integer."
  exit 1
fi

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "PORT must be an integer between 1 and 65535."
  exit 1
fi

if [[ "${ENABLE_NET_TUNING}" != "0" && "${ENABLE_NET_TUNING}" != "1" ]]; then
  echo "ENABLE_NET_TUNING must be 0 or 1."
  exit 1
fi

if ! [[ "${XRAY_NOFILE_LIMIT}" =~ ^[0-9]+$ ]]; then
  echo "XRAY_NOFILE_LIMIT must be a positive integer."
  exit 1
fi

if [[ -z "${SERVER_NAME}" || -z "${TARGET}" ]]; then
  echo "SERVER_NAME and TARGET cannot be empty."
  exit 1
fi

install_base_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl iproute2 kmod unzip
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl iproute kmod unzip
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl iproute kmod unzip
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl ca-certificates openssl iproute2 kmod unzip
  else
    echo "Unsupported package manager. Install curl, ca-certificates, and openssl first."
    exit 1
  fi
}

install_xray() {
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

detect_xray_bin() {
  if command -v xray >/dev/null 2>&1; then
    command -v xray
  elif [[ -x /usr/local/bin/xray ]]; then
    echo "/usr/local/bin/xray"
  else
    echo "xray binary not found after installation." >&2
    exit 1
  fi
}

detect_server_addr() {
  if [[ -n "${SERVER_ADDR:-}" ]]; then
    echo "${SERVER_ADDR}"
    return
  fi

  local addr
  addr="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${addr}" ]]; then
    addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -z "${addr}" ]]; then
    echo "Could not detect VPS public address. Re-run with SERVER_ADDR=your.domain.or.ip" >&2
    exit 1
  fi

  echo "${addr}"
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${PORT}/tcp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
  fi
}

sysctl_path_for_key() {
  local key="$1"
  printf '/proc/sys/%s\n' "${key//./\/}"
}

set_supported_sysctl() {
  local output_file="$1"
  local key="$2"
  local value="$3"
  local path
  path="$(sysctl_path_for_key "${key}")"

  if [[ ! -e "${path}" ]]; then
    echo "Skipping unsupported sysctl: ${key}"
    return
  fi

  if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
    printf '%s = %s\n' "${key}" "${value}" >>"${output_file}"
  else
    echo "Skipping sysctl rejected by kernel: ${key}=${value}"
  fi
}

apply_fq_to_default_interfaces() {
  if ! command -v ip >/dev/null 2>&1 || ! command -v tc >/dev/null 2>&1; then
    return
  fi

  ip -o route show default 2>/dev/null | awk '{print $5}' | sort -u | while read -r dev; do
    [[ -n "${dev}" ]] || continue
    if tc qdisc replace dev "${dev}" root fq 2>/dev/null; then
      echo "Applied fq qdisc to interface: ${dev}"
    else
      echo "Could not apply fq qdisc to interface: ${dev}"
    fi
  done
}

configure_network_stack() {
  if [[ "${ENABLE_NET_TUNING}" != "1" ]]; then
    echo "Network stack tuning skipped. Set ENABLE_NET_TUNING=1 to enable it."
    return
  fi

  echo "Applying conservative network stack tuning..."

  local modules_to_load=()
  if modprobe tcp_bbr 2>/dev/null; then
    modules_to_load+=("tcp_bbr")
  fi
  if modprobe sch_fq 2>/dev/null; then
    modules_to_load+=("sch_fq")
  fi
  if (( ${#modules_to_load[@]} > 0 )); then
    mkdir -p "$(dirname "${MODULES_LOAD_PATH}")"
    printf '%s\n' "${modules_to_load[@]}" >"${MODULES_LOAD_PATH}"
  fi

  local tmp_file available_cc
  tmp_file="$(mktemp)"
  available_cc="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"

  {
    echo "# Generated by install-vless-reality.sh"
    echo "# Goal: improve pacing, congestion behavior, and connection resilience on poor routes."
  } >"${tmp_file}"

  set_supported_sysctl "${tmp_file}" "net.core.default_qdisc" "fq"

  if printf '%s\n' "${available_cc}" | grep -qw "bbr"; then
    set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_congestion_control" "bbr"
  else
    echo "BBR is not available on this kernel. Keeping current congestion control."
  fi

  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_slow_start_after_idle" "0"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_mtu_probing" "1"

  set_supported_sysctl "${tmp_file}" "net.core.somaxconn" "4096"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_max_syn_backlog" "8192"
  set_supported_sysctl "${tmp_file}" "net.ipv4.ip_local_port_range" "1024 65535"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_tw_reuse" "1"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_fin_timeout" "15"

  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_keepalive_time" "600"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_keepalive_intvl" "30"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_keepalive_probes" "5"

  set_supported_sysctl "${tmp_file}" "net.core.rmem_max" "${TCP_BUFFER_MAX}"
  set_supported_sysctl "${tmp_file}" "net.core.wmem_max" "${TCP_BUFFER_MAX}"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_rmem" "4096 87380 ${TCP_BUFFER_MAX}"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_wmem" "4096 65536 ${TCP_BUFFER_MAX}"

  install -m 0644 "${tmp_file}" "${SYSCTL_TUNE_PATH}"
  rm -f "${tmp_file}"

  apply_fq_to_default_interfaces
}

configure_xray_service() {
  if ! id -u xray >/dev/null 2>&1; then
    useradd --system --home /nonexistent --no-create-home --shell /usr/sbin/nologin xray 2>/dev/null \
      || useradd -r -M -s /sbin/nologin xray
  fi

  chown -R xray:xray "$(dirname "${CONFIG_PATH}")" /var/log/xray /usr/local/share/xray 2>/dev/null || true
  chmod 750 "$(dirname "${CONFIG_PATH}")" 2>/dev/null || true
  chmod 640 "${CONFIG_PATH}" 2>/dev/null || true

  mkdir -p "${XRAY_SERVICE_OVERRIDE_DIR}"
  cat >"${XRAY_SERVICE_OVERRIDE_PATH}" <<EOF
[Service]
User=xray
Group=xray
LimitNOFILE=${XRAY_NOFILE_LIMIT}
EOF
  systemctl daemon-reload
}

test_xray_config() {
  local xray_bin="$1"

  "${xray_bin}" run -test -config "${CONFIG_PATH}"
  if command -v runuser >/dev/null 2>&1 && id -u xray >/dev/null 2>&1; then
    runuser -u xray -- "${xray_bin}" run -test -config "${CONFIG_PATH}" >/dev/null
  fi
}

restart_and_verify_xray() {
  systemctl enable xray >/dev/null
  systemctl restart xray
  sleep 1

  if ! systemctl is-active --quiet xray; then
    echo "Xray failed to start. Recent service log:" >&2
    journalctl -u xray --no-pager -n 50 >&2 || true
    exit 1
  fi

  if command -v ss >/dev/null 2>&1 && ! ss -lnt | awk '{print $4}' | grep -Eq "(:|\\])${PORT}$"; then
    echo "Xray is active, but port ${PORT}/tcp is not listening." >&2
    journalctl -u xray --no-pager -n 50 >&2 || true
    exit 1
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

make_vless_uri() {
  local uuid="$1"
  local host="$2"
  local public_key="$3"
  local short_id="$4"
  local name="vless-reality-vision"

  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none&spx=%%2F#%s\n' \
    "${uuid}" "${host}" "${PORT}" "${SERVER_NAME}" "${public_key}" "${short_id}" "${name}"
}

main() {
  umask 077

  echo "Installing dependencies..."
  install_base_deps

  echo "Installing or upgrading Xray..."
  install_xray

  local xray_bin
  xray_bin="$(detect_xray_bin)"

  local server_addr uuid keypair private_key public_key short_id
  server_addr="$(detect_server_addr)"
  uuid="$("${xray_bin}" uuid)"
  keypair="$("${xray_bin}" x25519)"
  private_key="$(printf '%s\n' "${keypair}" | awk -F': *' '/PrivateKey|Private key/ {print $2; exit}')"
  public_key="$(printf '%s\n' "${keypair}" | awk -F': *' '/Password \\(PublicKey\\)|PublicKey|Public key/ {print $2; exit}')"
  short_id="$(openssl rand -hex 8)"

  if [[ -z "${private_key}" || -z "${public_key}" ]]; then
    echo "Failed to generate REALITY x25519 key pair."
    exit 1
  fi

  mkdir -p "$(dirname "${CONFIG_PATH}")"
  if [[ -f "${CONFIG_PATH}" ]]; then
    cp -a "${CONFIG_PATH}" "${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  local server_name_json target_json private_key_json uuid_json email_json short_id_json
  server_name_json="$(json_escape "${SERVER_NAME}")"
  target_json="$(json_escape "${TARGET}")"
  private_key_json="$(json_escape "${private_key}")"
  uuid_json="$(json_escape "${uuid}")"
  email_json="$(json_escape "${EMAIL}")"
  short_id_json="$(json_escape "${short_id}")"

  cat >"${CONFIG_PATH}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid_json}",
            "flow": "xtls-rprx-vision",
            "email": "${email_json}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${target_json}",
          "serverNames": [
            "${server_name_json}"
          ],
          "privateKey": "${private_key_json}",
          "shortIds": [
            "${short_id_json}"
          ],
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

  configure_xray_service

  echo "Testing Xray configuration..."
  test_xray_config "${xray_bin}"

  echo "Opening firewall port if a supported firewall is active..."
  open_firewall_port

  configure_network_stack

  echo "Starting Xray..."
  restart_and_verify_xray

  local uri active_cc active_qdisc active_nofile active_user
  uri="$(make_vless_uri "${uuid}" "${server_addr}" "${public_key}" "${short_id}")"
  active_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  active_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  active_nofile="$(systemctl show xray -p LimitNOFILE --value 2>/dev/null || echo unknown)"
  active_user="$(systemctl show xray -p User --value 2>/dev/null || echo unknown)"

  cat >"${CLIENT_INFO_PATH}" <<EOF
VLESS REALITY Vision client parameters

Address: ${server_addr}
Port: ${PORT}
UUID: ${uuid}
Flow: xtls-rprx-vision
Transport: tcp/raw
Security: reality
SNI / serverName: ${SERVER_NAME}
REALITY public key / password: ${public_key}
Short ID: ${short_id}
Fingerprint: chrome
SpiderX: /

Import URI:
${uri}

Network tuning:
Enabled: ${ENABLE_NET_TUNING}
Congestion control: ${active_cc}
Default qdisc: ${active_qdisc}
Xray user: ${active_user}
Xray LimitNOFILE: ${active_nofile}
Sysctl profile: ${SYSCTL_TUNE_PATH}
Modules-load profile: ${MODULES_LOAD_PATH}

Server config:
${CONFIG_PATH}
EOF

  echo
  echo "Done."
  echo "Client parameters saved to: ${CLIENT_INFO_PATH}"
  echo
  cat "${CLIENT_INFO_PATH}"
}

main "$@"
