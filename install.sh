#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
EMAIL=""
UUID=""
PUBLIC_PORT="443"
FALLBACK_PORT="8080"
FALLBACK_ROOT="/var/www/single-vps-fallback"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
CERT_DIR=""
CERT_FILE=""
KEY_FILE=""
MANAGE_EXISTING_NFT="1"
CLEAN_OLD="1"
INSTALL_XRAY="1"
INSTALL_CADDY="1"
FALLBACK_IMPL="caddy"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash install-single-vps-443-vless.sh --domain example.com [options]

Required:
  --domain DOMAIN

Options:
  --email EMAIL             ACME email. Default: admin@DOMAIN
  --uuid UUID               VLESS UUID. Default: auto-generate
  --cert-file PATH          Use existing certificate fullchain
  --key-file PATH           Use existing private key
  --no-clean-old            Do not delete old experiment scripts/services
  --no-install-xray         Do not run the Xray official installer
  --no-install-caddy        Do not install/configure Caddy fallback
  --no-nft-clean            Do not touch existing nftables rules
  -h, --help

Assumptions:
  - Debian/Ubuntu VPS with systemd.
  - DOMAIN A record points to this VPS IPv4 before certificate issuance.
  - TCP 80 is reachable for ACME HTTP-01 if --cert-file/--key-file are not used.
  - TCP 443 is the only public proxy port.

Result:
  - Xray VLESS Vision TCP/TLS on 443 only
  - Caddy fallback on 127.0.0.1:8080
  - BBR + fq baseline
  - Old OpenVPN/adaptive/CAKE experiment files removed by default
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ "$#" -ge 2 ]] || die "missing value for --domain"
        DOMAIN="$2"
        shift 2
        ;;
      --email)
        [[ "$#" -ge 2 ]] || die "missing value for --email"
        EMAIL="$2"
        shift 2
        ;;
      --uuid)
        [[ "$#" -ge 2 ]] || die "missing value for --uuid"
        UUID="$2"
        shift 2
        ;;
      --cert-file)
        [[ "$#" -ge 2 ]] || die "missing value for --cert-file"
        CERT_FILE="$2"
        shift 2
        ;;
      --key-file)
        [[ "$#" -ge 2 ]] || die "missing value for --key-file"
        KEY_FILE="$2"
        shift 2
        ;;
      --no-clean-old)
        CLEAN_OLD="0"
        shift
        ;;
      --no-install-xray)
        INSTALL_XRAY="0"
        shift
        ;;
      --no-install-caddy)
        INSTALL_CADDY="0"
        shift
        ;;
      --no-nft-clean)
        MANAGE_EXISTING_NFT="0"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

require_root_and_os() {
  [[ "${EUID}" -eq 0 ]] || die "run as root"
  [[ -n "$DOMAIN" ]] || die "--domain is required"
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"

  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "this script targets Debian/Ubuntu, detected: ${PRETTY_NAME:-unknown}" ;;
  esac

  EMAIL="${EMAIL:-admin@${DOMAIN}}"
  CERT_DIR="/usr/local/etc/xray/certs"
}

make_uuid() {
  if [[ -n "$UUID" ]]; then
    return
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  elif have uuidgen; then
    UUID="$(uuidgen | tr 'A-Z' 'a-z')"
  else
    die "could not generate UUID; install uuid-runtime or pass --uuid"
  fi
}

detect_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }'
}

install_packages() {
  log "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates unzip openssl socat iproute2 nftables python3

  if [[ "$CERT_FILE" == "" || "$KEY_FILE" == "" ]]; then
    apt-get install -y certbot
  fi

  if [[ "$INSTALL_CADDY" == "1" ]]; then
    if apt-get install -y caddy; then
      FALLBACK_IMPL="caddy"
    else
      warn "Could not install caddy from apt; falling back to python3 local HTTP service"
      FALLBACK_IMPL="python"
      apt-get install -y python3
    fi
  else
    FALLBACK_IMPL="none"
  fi
}

backup_state() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="/root/single-vps-443-backup-${ts}"
  install -d -m 0700 "$BACKUP_DIR"

  cp -a "$XRAY_CONFIG" "$BACKUP_DIR/xray-config.json.before" 2>/dev/null || true
  cp -a /etc/caddy "$BACKUP_DIR/caddy" 2>/dev/null || true
  cp -a /etc/openvpn "$BACKUP_DIR/openvpn" 2>/dev/null || true
  cp -a /root/tcp-* "$BACKUP_DIR/" 2>/dev/null || true
  cp -a /etc/sysctl.d/99-tcp-adaptive-congestion.conf "$BACKUP_DIR/" 2>/dev/null || true
  cp -a /etc/sysctl.d/99-tcp-congestion-rescue.conf "$BACKUP_DIR/" 2>/dev/null || true
  cp -a /etc/systemd/system/tcp-adaptive-congestion.service "$BACKUP_DIR/" 2>/dev/null || true
  nft list ruleset > "$BACKUP_DIR/nft-before.ruleset" 2>/dev/null || true

  log "Backup saved to $BACKUP_DIR"
}

clean_old_experiments() {
  [[ "$CLEAN_OLD" == "1" ]] || return

  log "Cleaning old experiment services and files"
  systemctl disable --now tcp-adaptive-congestion.service 2>/dev/null || true
  systemctl disable --now openvpn-server@server.service 2>/dev/null || true
  systemctl disable --now openvpn@server.service 2>/dev/null || true
  systemctl stop 'openvpn*' 2>/dev/null || true

  rm -f /root/tcp-adaptive-congestion.sh
  rm -f /root/tcp-adaptive-congestion-v2.sh
  rm -f /root/tcp-congestion-rescue.sh
  rm -f /root/tcp-only-install.sh
  rm -f /root/tcp-only-install-minimal.sh
  rm -rf /root/tcp-vps-implementation
  rm -rf /root/tcp-vps-implementation.old-*
  rm -f /usr/local/sbin/tcp-adaptive-congestion
  rm -f /etc/tcp-adaptive-congestion.conf
  rm -f /etc/systemd/system/tcp-adaptive-congestion.service
  rm -rf /var/lib/tcp-adaptive-congestion
  rm -f /etc/sysctl.d/99-tcp-adaptive-congestion.conf
  rm -f /etc/sysctl.d/99-tcp-congestion-rescue.conf
  rm -rf /etc/openvpn/server

  systemctl daemon-reload
}

install_xray() {
  if [[ "$INSTALL_XRAY" != "1" && -x "$XRAY_BIN" ]]; then
    log "Using existing Xray binary: $XRAY_BIN"
    return
  fi

  if [[ "$INSTALL_XRAY" != "1" && ! -x "$XRAY_BIN" ]]; then
    die "Xray not found at $XRAY_BIN and --no-install-xray was set"
  fi

  log "Installing/updating Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  [[ -x "$XRAY_BIN" ]] || die "Xray install did not create $XRAY_BIN"
}

configure_fallback() {
  log "Configuring fallback site on 127.0.0.1:${FALLBACK_PORT}"
  install -d -m 0755 "$FALLBACK_ROOT"
  cat > "${FALLBACK_ROOT}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${DOMAIN}</title>
</head>
<body>
  <h1>${DOMAIN}</h1>
  <p>OK</p>
</body>
</html>
EOF

  if [[ "$FALLBACK_IMPL" == "caddy" ]]; then
    systemctl disable --now single-vps-fallback.service 2>/dev/null || true
    install -d -m 0755 /etc/caddy
    cp -a /etc/caddy/Caddyfile "${BACKUP_DIR}/Caddyfile.before" 2>/dev/null || true
    cat > /etc/caddy/Caddyfile <<EOF
:${FALLBACK_PORT} {
  bind 127.0.0.1
  root * ${FALLBACK_ROOT}
  file_server
  log {
    output discard
  }
}
EOF
    caddy validate --config /etc/caddy/Caddyfile
    systemctl enable --now caddy
    systemctl restart caddy
  elif [[ "$FALLBACK_IMPL" == "python" ]]; then
    systemctl disable --now caddy 2>/dev/null || true
    cat > /etc/systemd/system/single-vps-fallback.service <<EOF
[Unit]
Description=Single VPS local fallback website
After=network.target

[Service]
Type=simple
WorkingDirectory=${FALLBACK_ROOT}
ExecStart=/usr/bin/python3 -m http.server ${FALLBACK_PORT} --bind 127.0.0.1
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now single-vps-fallback.service
    systemctl restart single-vps-fallback.service
  else
    warn "Caddy disabled; make sure another service listens on 127.0.0.1:${FALLBACK_PORT}"
  fi
}

add_temp_acme_rule() {
  [[ "$MANAGE_EXISTING_NFT" == "1" ]] || return
  have nft || return
  nft list table inet filter >/dev/null 2>&1 || return
  nft list chain inet filter input >/dev/null 2>&1 || return
  nft add rule inet filter input tcp dport 80 accept comment single-vps-acme-temp 2>/dev/null || true
}

delete_temp_acme_rule() {
  [[ "$MANAGE_EXISTING_NFT" == "1" ]] || return
  have nft || return
  nft list chain inet filter input >/dev/null 2>&1 || return
  python3 - <<'PY'
import re
import subprocess

proc = subprocess.run(
    ["nft", "-a", "list", "chain", "inet", "filter", "input"],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
for line in proc.stdout.splitlines():
    if "single-vps-acme-temp" not in line:
        continue
    m = re.search(r"# handle (\d+)", line)
    if m:
        subprocess.run(
            ["nft", "delete", "rule", "inet", "filter", "input", "handle", m.group(1)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
PY
}

issue_or_copy_cert() {
  log "Preparing TLS certificate"
  install -d -m 0750 "$CERT_DIR"

  if [[ -n "$CERT_FILE" || -n "$KEY_FILE" ]]; then
    [[ -r "$CERT_FILE" ]] || die "--cert-file not readable: $CERT_FILE"
    [[ -r "$KEY_FILE" ]] || die "--key-file not readable: $KEY_FILE"
    cp "$CERT_FILE" "${CERT_DIR}/${DOMAIN}.fullchain.pem"
    cp "$KEY_FILE" "${CERT_DIR}/${DOMAIN}.privkey.pem"
  else
    local public_ip
    local domain_ip
    public_ip="$(curl -4fsS https://api.ipify.org || true)"
    domain_ip="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)"
    if [[ -n "$public_ip" && -n "$domain_ip" && "$public_ip" != "$domain_ip" ]]; then
      warn "$DOMAIN resolves to $domain_ip, but this VPS public IPv4 appears to be $public_ip"
      warn "ACME issuance may fail until DNS points to this VPS"
    fi

    if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
      add_temp_acme_rule
      if certbot certonly --standalone \
          --preferred-challenges http \
          --non-interactive --agree-tos \
          -m "$EMAIL" \
          -d "$DOMAIN"; then
        delete_temp_acme_rule
      else
        delete_temp_acme_rule
        die "certbot failed for ${DOMAIN}"
      fi
    else
      log "Existing Let's Encrypt certificate found for $DOMAIN"
    fi
    cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CERT_DIR}/${DOMAIN}.fullchain.pem"
    cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${CERT_DIR}/${DOMAIN}.privkey.pem"

    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > "/etc/letsencrypt/renewal-hooks/deploy/xray-${DOMAIN}-copy-cert.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/${DOMAIN}" ]]; then
  install -d -m 0750 "${CERT_DIR}"
  cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CERT_DIR}/${DOMAIN}.fullchain.pem"
  cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${CERT_DIR}/${DOMAIN}.privkey.pem"
  chown -R nobody:nogroup "${CERT_DIR}" 2>/dev/null || true
  chmod 0644 "${CERT_DIR}/${DOMAIN}.fullchain.pem"
  chmod 0640 "${CERT_DIR}/${DOMAIN}.privkey.pem"
  systemctl restart xray
fi
EOF
    chmod +x "/etc/letsencrypt/renewal-hooks/deploy/xray-${DOMAIN}-copy-cert.sh"
  fi

  chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || true
  chmod 0644 "${CERT_DIR}/${DOMAIN}.fullchain.pem"
  chmod 0640 "${CERT_DIR}/${DOMAIN}.privkey.pem"
}

write_xray_config() {
  log "Writing Xray 443-only VLESS Vision config"
  install -d -m 0755 "$(dirname "$XRAY_CONFIG")" /var/log/xray
  chown -R nobody:nogroup /var/log/xray 2>/dev/null || true

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-vision-443",
      "listen": "0.0.0.0",
      "port": ${PUBLIC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "main@single-vps-443"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "127.0.0.1:${FALLBACK_PORT}",
            "xver": 0
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "minVersion": "1.3",
          "alpn": [
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/${DOMAIN}.fullchain.pem",
              "keyFile": "${CERT_DIR}/${DOMAIN}.privkey.pem"
            }
          ]
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

  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
  systemctl enable --now xray
  systemctl restart xray
}

apply_tcp_baseline() {
  log "Applying BBR + fq baseline"
  local iface
  iface="$(detect_iface || true)"

  sysctl -w net.core.default_qdisc=fq >/dev/null
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
  else
    warn "BBR not available in this kernel"
  fi
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null
  sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null
  sysctl -w net.core.somaxconn=8192 >/dev/null

  cat > /etc/sysctl.d/99-tcp-baseline.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.core.somaxconn=8192
EOF

  if [[ -n "$iface" ]]; then
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc replace dev "$iface" root fq
  fi
}

clean_existing_nft() {
  [[ "$MANAGE_EXISTING_NFT" == "1" ]] || return
  have nft || return
  nft list table inet filter >/dev/null 2>&1 || return
  nft list chain inet filter input >/dev/null 2>&1 || return

  log "Cleaning existing nftables rules for 443-only public exposure"
  nft add rule inet filter input tcp dport '{' 22, 443 '}' accept 2>/dev/null || true

  python3 - <<'PY'
import re
import subprocess

def run(cmd):
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

for chain in ["input", "forward"]:
    proc = subprocess.run(
        ["nft", "-a", "list", "chain", "inet", "filter", chain],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    for line in proc.stdout.splitlines():
        m = re.search(r"# handle (\d+)", line)
        if not m:
            continue
        handle = m.group(1)
        if chain == "input" and ("8443" in line or "openvpn" in line.lower()):
            run(["nft", "delete", "rule", "inet", "filter", "input", "handle", handle])
        if chain == "forward" and ("tun0" in line or "openvpn" in line.lower()):
            run(["nft", "delete", "rule", "inet", "filter", "forward", "handle", handle])

run(["nft", "delete", "table", "ip", "openvpn_nat"])
PY
}

open_firewall_if_ufw() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "Updating UFW rules"
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw delete allow 8443/tcp >/dev/null 2>&1 || true
  fi
}

validate_install() {
  log "Validating services and ports"
  systemctl is-active --quiet xray || die "xray is not active"
  if [[ "$FALLBACK_IMPL" == "caddy" ]]; then
    systemctl is-active --quiet caddy || die "caddy is not active"
  elif [[ "$FALLBACK_IMPL" == "python" ]]; then
    systemctl is-active --quiet single-vps-fallback || die "single-vps-fallback is not active"
  fi

  ss -lntp | grep -q ':443 ' || die "port 443 is not listening"
  if ss -lntp | grep -q ':8443 '; then
    die "port 8443 is still listening"
  fi

  curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" >/dev/null \
    || warn "local fallback HTTPS check failed; VLESS may still work, inspect xray/caddy logs"
}

print_result() {
  local link
  local out
  link="vless://${UUID}@${DOMAIN}:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1#${DOMAIN}-443-single-vps"
  out="/root/${DOMAIN}-shadowrocket-vless-443.txt"
  printf '%s\n' "$link" > "$out"
  chmod 0600 "$out"

  cat <<EOF

Install complete.

Domain: ${DOMAIN}
Port: 443
Protocol: VLESS
Transport: TCP
TLS: 1.3
Flow: xtls-rprx-vision
Fallback: 127.0.0.1:${FALLBACK_PORT}
Backup: ${BACKUP_DIR}

Shadowrocket link:
${link}

Saved on server:
${out}

Useful checks:
systemctl status xray --no-pager
systemctl status caddy --no-pager
systemctl status single-vps-fallback --no-pager
ss -lntp | grep -E ':(22|443|8443|8080) '
curl -kI https://${DOMAIN}/
EOF
}

main() {
  parse_args "$@"
  require_root_and_os
  make_uuid
  backup_state
  install_packages
  clean_old_experiments
  install_xray
  configure_fallback
  issue_or_copy_cert
  write_xray_config
  apply_tcp_baseline
  clean_existing_nft
  open_firewall_if_ufw
  validate_install
  print_result
}

main "$@"
