#!/usr/bin/env bash
set -Eeuo pipefail

# Low-redundancy VLESS server installer for Debian/Ubuntu + systemd.
# Topology: client -> VLESS/TCP/REALITY/Vision -> Xray server -> direct egress.

CONFIG_PATH="/usr/local/etc/xray/config.json"
URI_PATH="/root/vless-reality-vision.uri"
CLIENT_JSON_PATH="/root/vless-reality-vision-client.json"
CLIENT_JSON_LEGACY_PATH="/root/vless-reality-vision-client-legacy.json"
XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

VLESS_PORT="${VLESS_PORT:-443}"
SERVER_ADDR="${SERVER_ADDR:-}"
REALITY_SNI="${REALITY_SNI:-www.bing.com}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SNI}:443}"
CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT:-chrome}"
INSTALL_XRAY="${INSTALL_XRAY:-1}"
ENABLE_BBR="${ENABLE_BBR:-0}"
CLIENT_TAG="${CLIENT_TAG:-vless-low-redundancy}"
UUID="${UUID:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
SHORT_ID="${SHORT_ID:-}"
REUSE_EXISTING="${REUSE_EXISTING:-1}"
CHECK_REALITY_TARGET="${CHECK_REALITY_TARGET:-1}"
XRAY_LOGLEVEL="${XRAY_LOGLEVEL:-warning}"
CONFIG_CANDIDATE=""
CONFIG_BACKUP=""

usage() {
  cat <<'USAGE'
Usage:
  sudo SERVER_ADDR=your.server.com bash install-vless-low-redundancy.sh

Optional env:
  VLESS_PORT=443
  REALITY_SNI=www.bing.com
  REALITY_DEST=www.bing.com:443
  CLIENT_FINGERPRINT=chrome
  UUID=<existing uuid>
  PRIVATE_KEY=<existing reality private key>
  PUBLIC_KEY=<existing reality public key>
  SHORT_ID=<hex short id>
  INSTALL_XRAY=1
  ENABLE_BBR=0
  REUSE_EXISTING=1
  CHECK_REALITY_TARGET=1
  XRAY_LOGLEVEL=warning

Output:
  /usr/local/etc/xray/config.json
  /root/vless-reality-vision.uri
  /root/vless-reality-vision-client.json
  /root/vless-reality-vision-client-legacy.json
USAGE
}

log() {
  printf '[vless-low] %s\n' "$*"
}

fatal() {
  printf '[vless-low] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${CONFIG_CANDIDATE}" && -f "${CONFIG_CANDIDATE}" ]]; then
    rm -f "${CONFIG_CANDIDATE}"
  fi
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fatal "run as root, for example: sudo SERVER_ADDR=your.server.com bash $0"
  fi
}

need_linux_systemd() {
  [[ "$(uname -s)" == "Linux" ]] || fatal "this script targets Linux servers"
  command -v systemctl >/dev/null 2>&1 || fatal "systemd is required"
}

validate_inputs() {
  [[ "${VLESS_PORT}" =~ ^[0-9]+$ ]] || fatal "VLESS_PORT must be numeric"
  (( VLESS_PORT >= 1 && VLESS_PORT <= 65535 )) || fatal "VLESS_PORT must be 1-65535"
  [[ "${REALITY_SNI}" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "REALITY_SNI contains invalid characters"
  [[ "${REALITY_DEST}" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]] || fatal "REALITY_DEST must look like host:port"
  [[ "${CLIENT_FINGERPRINT}" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "CLIENT_FINGERPRINT contains invalid characters"
  [[ "${CLIENT_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "CLIENT_TAG contains invalid characters"
  [[ "${REUSE_EXISTING}" =~ ^[01]$ ]] || fatal "REUSE_EXISTING must be 0 or 1"
  [[ "${CHECK_REALITY_TARGET}" =~ ^[01]$ ]] || fatal "CHECK_REALITY_TARGET must be 0 or 1"
  [[ "${ENABLE_BBR}" =~ ^[01]$ ]] || fatal "ENABLE_BBR must be 0 or 1"
  [[ "${INSTALL_XRAY}" =~ ^[01]$ ]] || fatal "INSTALL_XRAY must be 0 or 1"
  [[ "${XRAY_LOGLEVEL}" =~ ^(debug|info|warning|error|none)$ ]] || fatal "XRAY_LOGLEVEL must be debug, info, warning, error, or none"
  if [[ -n "${UUID}" ]]; then
    [[ "${UUID}" =~ ^[0-9a-fA-F-]{36}$ || ${#UUID} -lt 30 ]] || fatal "UUID must be a UUID or a VLESS custom id shorter than 30 bytes"
  fi
}

json_string_value() {
  local key="$1"
  [[ -f "${CONFIG_PATH}" ]] || return 1
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${CONFIG_PATH}" | head -n 1
}

json_first_array_string() {
  local key="$1"
  [[ -f "${CONFIG_PATH}" ]] || return 1
  sed -n "/\"${key}\"[[:space:]]*:[[:space:]]*\\[/ { n; s/.*\"\\([^\"]*\\)\".*/\\1/p; q; }" "${CONFIG_PATH}"
}

reuse_existing_config_values() {
  [[ "${REUSE_EXISTING}" == "1" && -f "${CONFIG_PATH}" ]] || return

  local value
  if [[ -z "${UUID}" ]]; then
    value="$(json_string_value "id" || true)"
    if [[ -n "${value}" ]]; then
      UUID="${value}"
      log "Reusing existing VLESS id"
    fi
  fi

  if [[ -z "${PRIVATE_KEY}" ]]; then
    value="$(json_string_value "privateKey" || true)"
    if [[ -n "${value}" ]]; then
      PRIVATE_KEY="${value}"
      log "Reusing existing REALITY private key"
    fi
  fi

  if [[ -z "${SHORT_ID}" ]]; then
    value="$(json_first_array_string "shortIds" || true)"
    if [[ -n "${value}" ]]; then
      SHORT_ID="${value}"
      log "Reusing existing REALITY shortId"
    fi
  fi
}

detect_public_addr() {
  if command -v curl >/dev/null 2>&1; then
    curl -4fsSL --max-time 8 https://api.ipify.org || true
  fi
}

resolve_server_addr() {
  if [[ -z "${SERVER_ADDR}" ]]; then
    SERVER_ADDR="$(detect_public_addr)"
  fi

  if [[ -z "${SERVER_ADDR}" && -t 0 ]]; then
    read -r -p "Server address or domain: " SERVER_ADDR
  fi

  [[ -n "${SERVER_ADDR}" ]] || fatal "SERVER_ADDR is required"
  [[ "${SERVER_ADDR}" =~ ^[A-Za-z0-9._:-]+$ ]] || fatal "SERVER_ADDR contains invalid characters"
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    if command -v curl >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && dpkg -s ca-certificates >/dev/null 2>&1; then
      log "Base packages already present"
      return
    fi

    log "Installing base packages"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl
    return
  fi

  command -v curl >/dev/null 2>&1 || fatal "curl is required"
  command -v openssl >/dev/null 2>&1 || fatal "openssl is required"
}

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    log "Xray already installed: $(command -v xray)"
    return
  fi

  [[ "${INSTALL_XRAY}" == "1" ]] || fatal "xray not found and INSTALL_XRAY=0"

  log "Installing Xray from official XTLS installer"
  bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install
  command -v xray >/dev/null 2>&1 || fatal "xray install failed"
}

generate_uuid() {
  if [[ -n "${UUID}" ]]; then
    return
  fi

  if command -v xray >/dev/null 2>&1; then
    UUID="$(xray uuid)"
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  else
    UUID="$(openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')"
  fi
}

generate_reality_keys() {
  if [[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]]; then
    return
  fi

  local pair
  if [[ -n "${PRIVATE_KEY}" ]]; then
    pair="$(xray x25519 -i "${PRIVATE_KEY}")"
  elif [[ -z "${PUBLIC_KEY}" ]]; then
    pair="$(xray x25519)"
  else
    fatal "PUBLIC_KEY without PRIVATE_KEY cannot build the server config"
  fi

  PRIVATE_KEY="$(printf '%s\n' "${pair}" | awk -F': ' '/^(Private key|PrivateKey)/ {print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "${pair}" | awk -F': ' '/^(Public key|PublicKey|Password \(PublicKey\))/ {print $2; exit}')"

  [[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || fatal "failed to generate REALITY x25519 keys"
}

generate_short_id() {
  if [[ -z "${SHORT_ID}" ]]; then
    SHORT_ID="$(openssl rand -hex 8)"
  fi
  [[ "${SHORT_ID}" =~ ^[0-9a-fA-F]{0,16}$ ]] || fatal "SHORT_ID must be 0-16 hex chars"
}

check_reality_target() {
  [[ "${CHECK_REALITY_TARGET}" == "1" ]] || return

  if ! xray help tls >/dev/null 2>&1; then
    log "Skipping REALITY target check: xray tls is unavailable"
    return
  fi

  log "Checking REALITY target TLS handshake: ${REALITY_SNI}"
  local output chain_len
  if ! output="$(timeout 15 xray tls ping "${REALITY_SNI}" 2>&1)"; then
    printf '%s\n' "${output}" >&2
    fatal "REALITY target TLS check failed: ${REALITY_SNI}"
  fi

  if ! printf '%s\n' "${output}" | grep -q "Pinging with SNI"; then
    log "REALITY target check returned an unexpected format; continuing after xray config test"
    return
  fi

  if ! printf '%s\n' "${output}" | awk 'seen && /Handshake succeeded/ {ok=1} /Pinging with SNI/ {seen=1} END {exit ok ? 0 : 1}'; then
    printf '%s\n' "${output}" >&2
    fatal "REALITY target does not complete TLS handshake with SNI: ${REALITY_SNI}"
  fi

  chain_len="$(printf '%s\n' "${output}" | awk -F': *' '/Certificate chain.*total length/ {print $2}' | tail -n 1 | awk '{print $1}')"
  if [[ -n "${chain_len}" && "${chain_len}" =~ ^[0-9]+$ && "${chain_len}" -gt 7000 ]]; then
    log "Warning: ${REALITY_SNI} certificate chain is large (${chain_len}); choose a smaller REALITY target if handshakes reset"
  fi
}

validate_runtime_values() {
  [[ -n "${UUID}" ]] || fatal "UUID is empty"
  [[ -n "${PRIVATE_KEY}" ]] || fatal "PRIVATE_KEY is empty"
  [[ -n "${PUBLIC_KEY}" ]] || fatal "PUBLIC_KEY is empty"
  [[ -n "${SHORT_ID}" ]] || fatal "SHORT_ID is empty"
  [[ "${SHORT_ID}" =~ ^[0-9a-fA-F]{0,16}$ ]] || fatal "SHORT_ID must be 0-16 hex chars"
}

render_xray_config() {
  local output="$1"
  umask 077
  cat > "${output}" <<EOF
{
  "log": {
    "loglevel": "${XRAY_LOGLEVEL}"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision-in",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "${CLIENT_TAG}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
}

write_xray_config() {
  install -d -m 755 "$(dirname "${CONFIG_PATH}")"
  CONFIG_CANDIDATE="$(mktemp /tmp/vless-low-xray.XXXXXX.json)"
  render_xray_config "${CONFIG_CANDIDATE}"
  log "Rendered candidate config: ${CONFIG_CANDIDATE}"
}

write_client_outputs() {
  local uri
  uri="vless://${UUID}@${SERVER_ADDR}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${CLIENT_FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${CLIENT_TAG}"

  umask 077
  printf '%s\n' "${uri}" > "${URI_PATH}"

  cat > "${CLIENT_JSON_PATH}" <<EOF
{
  "protocol": "vless",
  "settings": {
    "address": "${SERVER_ADDR}",
    "port": ${VLESS_PORT},
    "id": "${UUID}",
    "encryption": "none",
    "flow": "xtls-rprx-vision"
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "serverName": "${REALITY_SNI}",
      "fingerprint": "${CLIENT_FINGERPRINT}",
      "password": "${PUBLIC_KEY}",
      "shortId": "${SHORT_ID}"
    }
  },
  "mux": {
    "enabled": false
  }
}
EOF

  cat > "${CLIENT_JSON_LEGACY_PATH}" <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "${SERVER_ADDR}",
        "port": ${VLESS_PORT},
        "users": [
          {
            "id": "${UUID}",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "${REALITY_SNI}",
      "fingerprint": "${CLIENT_FINGERPRINT}",
      "publicKey": "${PUBLIC_KEY}",
      "shortId": "${SHORT_ID}"
    }
  },
  "mux": {
    "enabled": false
  }
}
EOF

  log "Client URI saved to ${URI_PATH}"
  log "Client outbound JSON saved to ${CLIENT_JSON_PATH}"
  log "Legacy client outbound JSON saved to ${CLIENT_JSON_LEGACY_PATH}"
  printf '\n%s\n%s\n\n' "VLESS URI:" "${uri}"
}

xray_test_config() {
  local config="$1"
  if xray help 2>/dev/null | grep -Eq '^[[:space:]]+test[[:space:]]'; then
    xray test -config "${config}"
  else
    xray run -test -config "${config}"
  fi
}

rollback_config() {
  [[ -n "${CONFIG_BACKUP}" && -f "${CONFIG_BACKUP}" ]] || return
  log "Rolling back config from ${CONFIG_BACKUP}"
  cp -a "${CONFIG_BACKUP}" "${CONFIG_PATH}"
  systemctl restart xray || true
}

install_config_for_xray_service() {
  local service_user service_group

  service_user="$(systemctl show -p User --value xray 2>/dev/null || true)"
  if [[ -n "${service_user}" && "${service_user}" != "root" ]] && id "${service_user}" >/dev/null 2>&1; then
    service_group="$(id -gn "${service_user}")"
    install -o "${service_user}" -g "${service_group}" -m 600 "${CONFIG_CANDIDATE}" "${CONFIG_PATH}"
    log "Installed config readable by xray service user: ${service_user}:${service_group}"
  else
    install -m 600 "${CONFIG_CANDIDATE}" "${CONFIG_PATH}"
    log "Installed config readable by root-run xray service"
  fi
}

test_and_restart_xray() {
  [[ -n "${CONFIG_CANDIDATE}" && -f "${CONFIG_CANDIDATE}" ]] || fatal "candidate config is missing"

  log "Testing candidate Xray config"
  xray_test_config "${CONFIG_CANDIDATE}"

  if [[ -f "${CONFIG_PATH}" ]]; then
    CONFIG_BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${CONFIG_PATH}" "${CONFIG_BACKUP}"
    log "Backed up existing config to ${CONFIG_BACKUP}"
  fi

  install_config_for_xray_service

  log "Restarting Xray"
  systemctl enable xray >/dev/null
  if ! systemctl restart xray; then
    rollback_config
    fatal "xray restart failed"
  fi

  sleep 1
  if ! systemctl is-active --quiet xray; then
    rollback_config
    fatal "xray is not active after restart"
  fi

  systemctl --no-pager --full status xray | sed -n '1,12p'
}

open_firewall_if_present() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "Opening TCP/${VLESS_PORT} in ufw"
    ufw allow "${VLESS_PORT}/tcp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "Opening TCP/${VLESS_PORT} in firewalld"
    firewall-cmd --permanent --add-port="${VLESS_PORT}/tcp"
    firewall-cmd --reload
  fi
}

enable_bbr_if_requested() {
  [[ "${ENABLE_BBR}" == "1" ]] || return

  log "Enabling BBR TCP congestion control"
  cat > /etc/sysctl.d/99-vless-low-redundancy.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
}

main() {
  trap cleanup EXIT

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  need_root
  need_linux_systemd
  validate_inputs
  resolve_server_addr
  install_packages
  install_xray
  reuse_existing_config_values
  generate_uuid
  generate_reality_keys
  generate_short_id
  validate_runtime_values
  check_reality_target
  write_xray_config
  open_firewall_if_present
  enable_bbr_if_requested
  test_and_restart_xray
  write_client_outputs

  log "Done"
}

main "$@"
