#!/usr/bin/env bash
set -euo pipefail

# Shadowrocket VLESS TCP+TLS installer for a single VPS.
# It installs a legitimate Xray VLESS TCP+TLS service, applies TCP performance
# tuning, runs a lightweight adaptive health optimizer, and prints a
# Shadowrocket-compatible vless:// line.
#
# It does not implement traffic camouflage, anti-detection, or censorship
# bypass-specific behavior.

APP_NAME="shadowrocket-vless-tcp"
INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
STATE_DIR="/etc/${APP_NAME}"
STATE_FILE="${STATE_DIR}/config.env"
RUNTIME_DIR="/var/lib/${APP_NAME}"
RUNTIME_STATE="${RUNTIME_DIR}/state.env"
LOG_PATH="/var/log/${APP_NAME}.log"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_PATH="${XRAY_CONFIG_DIR}/config.json"
XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"

SYSCTL_PATH="/etc/sysctl.d/99-${APP_NAME}.conf"
OPTIMIZER_SERVICE="/etc/systemd/system/${APP_NAME}-optimizer.service"
OPTIMIZER_TIMER="/etc/systemd/system/${APP_NAME}-optimizer.timer"
CERT_RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-xray.sh"

DOMAIN=""
EMAIL=""
PORT="443"
UUID=""
LINE_NAME="vless-vps"
CERT_FILE=""
KEY_FILE=""
INSTALL_CERTBOT="1"
SELF_SIGNED="0"
ALLOW_INSECURE="0"
ENABLE_BBR="1"
ENABLE_OPTIMIZER="1"
HIGH_CONN_THRESHOLD="1200"
LOW_CONN_THRESHOLD="300"
PORT_FAIL_RESTART_THRESHOLD="3"
MIN_RESTART_INTERVAL_SEC="300"

usage() {
  cat <<'USAGE'
Shadowrocket VLESS TCP+TLS installer

Usage:
  sudo bash shadowrocket_vless_tcp_tls_install.sh install \
    --domain example.com \
    --email admin@example.com \
    --port 443 \
    --name my-vps

  sudo shadowrocket-vless-tcp show
  sudo shadowrocket-vless-tcp status
  sudo shadowrocket-vless-tcp optimizer-run
  sudo shadowrocket-vless-tcp uninstall

Required:
  --domain  Domain name pointing to this VPS.
  --email   Email for Let's Encrypt certificate registration.

Optional:
  --port       TLS listen port, default: 443.
  --uuid       Custom VLESS UUID. Default: generated automatically.
  --name       Shadowrocket line name, default: vless-vps.
  --cert       Existing TLS certificate fullchain path.
  --key        Existing TLS private key path.
  --self-signed Generate a self-signed certificate. Useful for IP-only VPS.
  --no-certbot Do not request a Let's Encrypt certificate.
  --no-bbr     Do not try to enable BBR.
  --no-optimizer Disable adaptive TCP health optimizer.

Example:
  sudo bash shadowrocket_vless_tcp_tls_install.sh install \
    --domain proxy.example.com \
    --email me@example.com \
    --port 443 \
    --name tokyo-vps

Notes:
  - Supports Debian/Ubuntu systems with systemd.
  - Ports 80/tcp and the selected TLS port must be reachable from the Internet
    when using Let's Encrypt standalone mode.
  - The generated Shadowrocket line is VLESS over TCP with TLS:
    vless://UUID@DOMAIN:PORT?encryption=none&security=tls&sni=DOMAIN&type=tcp&headerType=none#NAME
USAGE
}

log() {
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $msg"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    mkdir -p "$(dirname "$LOG_PATH")"
    echo "[$ts] $msg" >> "$LOG_PATH"
  fi
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "please run as root"
}

need_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "this script is intended for Linux VPS hosts"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "invalid port: $1"
  (( "$1" >= 1 && "$1" <= 65535 )) || die "port out of range: $1"
}

validate_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || die "domain contains unsupported characters: $1"
  [[ "$1" == *.* ]] || die "domain should be a real DNS name, for example proxy.example.com"
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "invalid UUID: $1"
}

sanitize_name() {
  local raw="$1"
  echo "$raw" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+//; s/_+$//'
}

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "--domain requires a value"
        DOMAIN="$2"
        shift 2
        ;;
      --email)
        [[ $# -ge 2 ]] || die "--email requires a value"
        EMAIL="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port requires a value"
        PORT="$2"
        shift 2
        ;;
      --uuid)
        [[ $# -ge 2 ]] || die "--uuid requires a value"
        UUID="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value"
        LINE_NAME="$(sanitize_name "$2")"
        [[ -n "$LINE_NAME" ]] || LINE_NAME="vless-vps"
        shift 2
        ;;
      --cert)
        [[ $# -ge 2 ]] || die "--cert requires a value"
        CERT_FILE="$2"
        INSTALL_CERTBOT="0"
        shift 2
        ;;
      --key)
        [[ $# -ge 2 ]] || die "--key requires a value"
        KEY_FILE="$2"
        INSTALL_CERTBOT="0"
        shift 2
        ;;
      --self-signed)
        INSTALL_CERTBOT="0"
        SELF_SIGNED="1"
        ALLOW_INSECURE="1"
        shift
        ;;
      --allow-insecure)
        ALLOW_INSECURE="1"
        shift
        ;;
      --no-certbot)
        INSTALL_CERTBOT="0"
        shift
        ;;
      --no-bbr)
        ENABLE_BBR="0"
        shift
        ;;
      --no-optimizer)
        ENABLE_OPTIMIZER="0"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  [[ -n "$DOMAIN" ]] || die "--domain is required"
  validate_domain "$DOMAIN"

  validate_port "$PORT"

  if [[ -n "$UUID" ]]; then
    validate_uuid "$UUID"
  else
    UUID="$(generate_uuid)"
  fi

  if [[ "$INSTALL_CERTBOT" == "1" ]]; then
    [[ -n "$EMAIL" ]] || die "--email is required when using Let's Encrypt"
  elif [[ "$SELF_SIGNED" == "1" ]]; then
    CERT_FILE="${STATE_DIR}/selfsigned.crt"
    KEY_FILE="${STATE_DIR}/selfsigned.key"
  else
    [[ -n "$CERT_FILE" && -n "$KEY_FILE" ]] || die "--cert and --key are required with --no-certbot"
    [[ -f "$CERT_FILE" ]] || die "certificate file not found: $CERT_FILE"
    [[ -f "$KEY_FILE" ]] || die "private key file not found: $KEY_FILE"
  fi
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "not installed; run install first"
  # shellcheck source=/dev/null
  source "$STATE_FILE"
}

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi

  local h
  h="$(openssl rand -hex 16)"
  printf '%s-%s-%s-%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

install_dependencies() {
  have_cmd apt-get || die "only Debian/Ubuntu with apt-get is supported by this installer"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip openssl iproute2 procps

  if [[ "$INSTALL_CERTBOT" == "1" ]]; then
    apt-get install -y certbot
  fi
}

detect_xray_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      echo "Xray-linux-64.zip"
      ;;
    aarch64|arm64)
      echo "Xray-linux-arm64-v8a.zip"
      ;;
    armv7l)
      echo "Xray-linux-arm32-v7a.zip"
      ;;
    *)
      die "unsupported architecture for automatic Xray install: ${arch}"
      ;;
  esac
}

install_xray() {
  local tag asset url tmp zip

  asset="$(detect_xray_asset)"
  tag="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    | head -n 1)"
  [[ -n "$tag" ]] || die "failed to detect latest Xray release"

  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
  tmp="$(mktemp -d)"
  zip="${tmp}/${asset}"

  log "downloading Xray ${tag} for $(uname -m)"
  curl -fL "$url" -o "$zip"
  unzip -oq "$zip" -d "$tmp/xray"

  install -m 0755 "$tmp/xray/xray" "$XRAY_BIN"
  mkdir -p "$XRAY_ASSET_DIR" "$XRAY_CONFIG_DIR" /var/log/xray
  if [[ -f "$tmp/xray/geoip.dat" ]]; then
    install -m 0644 "$tmp/xray/geoip.dat" "${XRAY_ASSET_DIR}/geoip.dat"
  fi
  if [[ -f "$tmp/xray/geosite.dat" ]]; then
    install -m 0644 "$tmp/xray/geosite.dat" "${XRAY_ASSET_DIR}/geosite.dat"
  fi

  rm -rf "$tmp"
  log "Xray installed: $("$XRAY_BIN" version | head -n 1)"
}

port_is_listening() {
  local port="$1"
  if have_cmd ss; then
    ss -Htlpn "( sport = :${port} )" 2>/dev/null | grep -q .
    return $?
  fi
  return 1
}

warn_domain_resolution() {
  local resolved_ip public_ip
  resolved_ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
  public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

  if [[ -z "$resolved_ip" ]]; then
    log "warning: domain does not resolve through local DNS: ${DOMAIN}"
    return 0
  fi

  if [[ -n "$public_ip" && "$resolved_ip" != "$public_ip" ]]; then
    log "warning: ${DOMAIN} resolves to ${resolved_ip}, VPS public IPv4 appears to be ${public_ip}"
  else
    log "domain resolution check: ${DOMAIN} -> ${resolved_ip}"
  fi
}

obtain_certificate() {
  if [[ "$SELF_SIGNED" == "1" ]]; then
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"

    local san
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      san="IP:${DOMAIN}"
    else
      san="DNS:${DOMAIN}"
    fi

    log "generating self-signed TLS certificate for ${DOMAIN}"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$KEY_FILE" \
      -out "$CERT_FILE" \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=${san}" >/dev/null 2>&1
    chmod 0600 "$KEY_FILE"
    chmod 0644 "$CERT_FILE"
    return 0
  fi

  if [[ "$INSTALL_CERTBOT" != "1" ]]; then
    log "using existing certificate files"
    return 0
  fi

  CERT_FILE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  KEY_FILE="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

  warn_domain_resolution

  if port_is_listening 80; then
    log "warning: port 80 is already in use; certbot standalone mode may fail"
  fi

  log "requesting Let's Encrypt certificate for ${DOMAIN}"
  certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --keep-until-expiring \
    --email "$EMAIL" \
    -d "$DOMAIN"

  [[ -f "$CERT_FILE" ]] || die "certificate was not created: $CERT_FILE"
  [[ -f "$KEY_FILE" ]] || die "private key was not created: $KEY_FILE"

  mkdir -p "$(dirname "$CERT_RENEW_HOOK")"
  cat > "$CERT_RENEW_HOOK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart xray.service >/dev/null 2>&1 || true
EOF
  chmod 0755 "$CERT_RENEW_HOOK"
}

backup_existing_config() {
  if [[ -f "$XRAY_CONFIG_PATH" ]]; then
    local backup
    backup="${XRAY_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$XRAY_CONFIG_PATH" "$backup"
    log "existing Xray config backed up: ${backup}"
  fi
}

write_xray_config() {
  mkdir -p "$XRAY_CONFIG_DIR"
  cat > "$XRAY_CONFIG_PATH" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": false,
        "statsUserDownlink": false
      }
    }
  },
  "inbounds": [
    {
      "tag": "vless-tcp-tls",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "level": 0,
            "email": "shadowrocket@local"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "minVersion": "1.2",
          "certificates": [
            {
              "certificateFile": "${CERT_FILE}",
              "keyFile": "${KEY_FILE}"
            }
          ]
        },
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        }
      },
      "sniffing": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ]
}
EOF

  "$XRAY_BIN" run -test -config "$XRAY_CONFIG_PATH" >/dev/null
  chmod 0644 "$XRAY_CONFIG_PATH"
  log "Xray config written and validated: ${XRAY_CONFIG_PATH}"
}

write_xray_service() {
  cat > "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service - VLESS TCP TLS
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_PATH}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now xray.service
}

choose_congestion_control() {
  if [[ "$ENABLE_BBR" != "1" ]]; then
    echo "cubic"
    return 0
  fi

  modprobe tcp_bbr >/dev/null 2>&1 || true
  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ "$available" == *"bbr"* ]]; then
    echo "bbr"
  else
    echo "cubic"
  fi
}

sysctl_set_runtime() {
  local key="$1"
  local value="$2"
  if sysctl -n "$key" >/dev/null 2>&1; then
    sysctl -w "${key}=${value}" >/dev/null || true
  fi
}

apply_tcp_baseline() {
  local cc
  cc="$(choose_congestion_control)"

  cat > "$SYSCTL_PATH" <<EOF
# Managed by ${APP_NAME}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
fs.file-max = 2097152
EOF
  sysctl --system >/dev/null || true
  sysctl_set_runtime "net.core.default_qdisc" "fq"
  sysctl_set_runtime "net.ipv4.tcp_congestion_control" "$cc"
  log "TCP baseline applied, congestion_control=${cc}"
}

apply_profile_normal() {
  sysctl_set_runtime "net.ipv4.tcp_rmem" "4096 87380 33554432"
  sysctl_set_runtime "net.ipv4.tcp_wmem" "4096 65536 33554432"
  sysctl_set_runtime "net.ipv4.tcp_notsent_lowat" "16384"
  sysctl_set_runtime "net.core.somaxconn" "32768"
  sysctl_set_runtime "net.ipv4.tcp_max_syn_backlog" "32768"
}

apply_profile_high_conn() {
  sysctl_set_runtime "net.ipv4.tcp_rmem" "4096 131072 67108864"
  sysctl_set_runtime "net.ipv4.tcp_wmem" "4096 131072 67108864"
  sysctl_set_runtime "net.ipv4.tcp_notsent_lowat" "32768"
  sysctl_set_runtime "net.core.somaxconn" "65535"
  sysctl_set_runtime "net.ipv4.tcp_max_syn_backlog" "65535"
}

count_established() {
  local port="$1"
  ss -Htan state established "( sport = :${port} or dport = :${port} )" 2>/dev/null | wc -l | awk '{print $1}'
}

read_runtime_state() {
  if [[ -f "$RUNTIME_STATE" ]]; then
    # shellcheck source=/dev/null
    source "$RUNTIME_STATE"
  fi
  PROFILE="${PROFILE:-normal}"
  PORT_FAIL_COUNT="${PORT_FAIL_COUNT:-0}"
  LAST_RESTART="${LAST_RESTART:-0}"
}

write_runtime_state() {
  mkdir -p "$RUNTIME_DIR"
  cat > "$RUNTIME_STATE" <<EOF
PROFILE="${PROFILE}"
PORT_FAIL_COUNT="${PORT_FAIL_COUNT}"
LAST_RESTART="${LAST_RESTART}"
EOF
}

restart_xray_if_allowed() {
  local now="$1"
  if (( now - LAST_RESTART < MIN_RESTART_INTERVAL_SEC )); then
    log "xray restart skipped; min interval not reached"
    return 0
  fi
  systemctl restart xray.service || true
  LAST_RESTART="$now"
  log "xray restarted by optimizer"
}

optimizer_run() {
  need_root
  need_linux
  load_state
  read_runtime_state

  local established now previous_profile
  established="$(count_established "$PORT")"
  now="$(date +%s)"
  previous_profile="$PROFILE"

  if (( established >= HIGH_CONN_THRESHOLD )); then
    PROFILE="high_conn"
    apply_profile_high_conn
  elif (( established <= LOW_CONN_THRESHOLD )); then
    PROFILE="normal"
    apply_profile_normal
  fi

  if [[ "$PROFILE" != "$previous_profile" ]]; then
    log "optimizer profile switched: ${previous_profile} -> ${PROFILE}, established=${established}"
  fi

  if ! systemctl is-active --quiet xray.service; then
    restart_xray_if_allowed "$now"
    PORT_FAIL_COUNT="0"
  elif ! port_is_listening "$PORT"; then
    PORT_FAIL_COUNT="$((PORT_FAIL_COUNT + 1))"
    log "optimizer port check failed: port=${PORT}, count=${PORT_FAIL_COUNT}"
    if (( PORT_FAIL_COUNT >= PORT_FAIL_RESTART_THRESHOLD )); then
      restart_xray_if_allowed "$now"
      PORT_FAIL_COUNT="0"
    fi
  else
    PORT_FAIL_COUNT="0"
  fi

  write_runtime_state
  log "optimizer run complete: port=${PORT}, established=${established}, profile=${PROFILE}"
}

write_optimizer_units() {
  [[ "$ENABLE_OPTIMIZER" == "1" ]] || return 0

  cat > "$OPTIMIZER_SERVICE" <<EOF
[Unit]
Description=Shadowrocket VLESS TCP adaptive optimizer
After=network-online.target xray.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} optimizer-run
EOF

  cat > "$OPTIMIZER_TIMER" <<EOF
[Unit]
Description=Run Shadowrocket VLESS TCP adaptive optimizer periodically

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}-optimizer.timer" >/dev/null
  log "adaptive optimizer enabled: ${APP_NAME}-optimizer.timer"
}

configure_firewall_if_present() {
  if have_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null || true
    ufw allow "${PORT}/tcp" >/dev/null || true
    log "ufw rules added for 80/tcp and ${PORT}/tcp"
  fi

  if have_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp >/dev/null || true
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
    log "firewalld rules added for 80/tcp and ${PORT}/tcp"
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
DOMAIN="${DOMAIN}"
EMAIL="${EMAIL}"
PORT="${PORT}"
UUID="${UUID}"
LINE_NAME="${LINE_NAME}"
CERT_FILE="${CERT_FILE}"
KEY_FILE="${KEY_FILE}"
ENABLE_OPTIMIZER="${ENABLE_OPTIMIZER}"
ALLOW_INSECURE="${ALLOW_INSECURE}"
HIGH_CONN_THRESHOLD="${HIGH_CONN_THRESHOLD}"
LOW_CONN_THRESHOLD="${LOW_CONN_THRESHOLD}"
PORT_FAIL_RESTART_THRESHOLD="${PORT_FAIL_RESTART_THRESHOLD}"
MIN_RESTART_INTERVAL_SEC="${MIN_RESTART_INTERVAL_SEC}"
EOF
  chmod 0600 "$STATE_FILE"
}

shadowrocket_line() {
  load_state
  local insecure_param=""
  if [[ "${ALLOW_INSECURE:-0}" == "1" ]]; then
    insecure_param="&allowInsecure=1"
  fi
  echo "vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=tcp&headerType=none${insecure_param}#${LINE_NAME}"
}

print_result() {
  echo
  echo "Install complete."
  echo
  echo "Shadowrocket line:"
  shadowrocket_line
  echo
  echo "Commands:"
  echo "  sudo ${APP_NAME} show"
  echo "  sudo ${APP_NAME} status"
  echo "  sudo ${APP_NAME} uninstall"
  echo
}

install_all() {
  need_root
  need_linux
  have_cmd systemctl || die "systemd is required"
  parse_install_args "$@"

  install -m 0755 "$0" "$INSTALL_PATH"
  install_dependencies
  install_xray
  configure_firewall_if_present
  obtain_certificate
  backup_existing_config
  write_xray_config
  write_xray_service
  apply_tcp_baseline
  save_state
  write_optimizer_units

  sleep 1
  systemctl is-active --quiet xray.service || die "xray.service failed to start; inspect: journalctl -u xray -n 80"
  port_is_listening "$PORT" || die "xray is active but port ${PORT} is not listening"

  print_result
}

show_status_value() {
  local key="$1"
  local value
  value="$(sysctl -n "$key" 2>/dev/null || echo n/a)"
  printf '  %-38s %s\n' "$key" "$value"
}

status() {
  need_linux
  load_state

  echo "${APP_NAME} status"
  echo
  echo "Service:"
  echo "  xray:            $(systemctl is-active xray.service 2>/dev/null || echo n/a)"
  echo "  optimizer:       $(systemctl is-active "${APP_NAME}-optimizer.timer" 2>/dev/null || echo disabled)"
  echo "  listening:       $(port_is_listening "$PORT" && echo yes || echo no)"
  echo "  established:     $(count_established "$PORT")"
  echo
  echo "Config:"
  echo "  domain:          ${DOMAIN}"
  echo "  port:            ${PORT}"
  echo "  uuid:            ${UUID}"
  echo "  line name:       ${LINE_NAME}"
  echo "  xray config:     ${XRAY_CONFIG_PATH}"
  echo "  state:           ${STATE_FILE}"
  echo
  echo "Shadowrocket line:"
  shadowrocket_line
  echo
  echo "TCP settings:"
  show_status_value "net.core.default_qdisc"
  show_status_value "net.ipv4.tcp_congestion_control"
  show_status_value "net.core.somaxconn"
  show_status_value "net.ipv4.tcp_max_syn_backlog"
  show_status_value "net.ipv4.tcp_rmem"
  show_status_value "net.ipv4.tcp_wmem"
  show_status_value "net.ipv4.tcp_notsent_lowat"
}

uninstall() {
  need_root
  need_linux

  systemctl disable --now "${APP_NAME}-optimizer.timer" >/dev/null 2>&1 || true
  rm -f "$OPTIMIZER_TIMER" "$OPTIMIZER_SERVICE"

  systemctl disable --now xray.service >/dev/null 2>&1 || true
  rm -f "$XRAY_SERVICE"
  rm -f "$SYSCTL_PATH"
  rm -f "$INSTALL_PATH"
  rm -rf "$RUNTIME_DIR"
  rm -f "$CERT_RENEW_HOOK"

  systemctl daemon-reload >/dev/null 2>&1 || true
  log "uninstalled systemd units and optimizer; kept ${STATE_FILE}, ${XRAY_CONFIG_PATH}, and certificates"
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi
  shift || true

  case "$cmd" in
    install)
      install_all "$@"
      ;;
    show)
      shadowrocket_line
      ;;
    status)
      status
      ;;
    optimizer-run)
      optimizer_run
      ;;
    uninstall)
      uninstall
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
