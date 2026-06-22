#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash bootstrap-tcp-line.sh --domain example.com --email admin@example.com [--uuid UUID]

What it installs:
  - Xray VLESS + TCP + TLS + Vision on 443/tcp
  - Caddy fallback website on 127.0.0.1:8080
  - acme.sh certificate under /etc/ssl/rescue-gateway
  - BBR/fq and conservative TCP keepalive tuning

Required before running:
  - Debian/Ubuntu VPS with root access
  - DOMAIN A/AAAA record already points to this VPS
  - Ports 80/tcp and 443/tcp reachable during install
EOF
}

DOMAIN=""
EMAIL=""
VLESS_UUID=""
CLIENT_MIXED_PORT="2080"
SITE_ROOT="/var/www/rescue-site"
FALLBACK_LISTEN="127.0.0.1:8080"
CERT_DIR="/etc/ssl/rescue-gateway"
TLS_CERT="${CERT_DIR}/fullchain.cer"
TLS_KEY="${CERT_DIR}/private.key"
STATE_DIR="/etc/rescue-gateway"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      shift 2
      ;;
    --uuid)
      VLESS_UUID="${2:-}"
      shift 2
      ;;
    --client-port)
      CLIENT_MIXED_PORT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if [[ -z "${DOMAIN}" || -z "${EMAIL}" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "${VLESS_UUID}" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    VLESS_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
  fi
fi

if ! [[ "${CLIENT_MIXED_PORT}" =~ ^[0-9]+$ ]]; then
  echo "--client-port must be numeric." >&2
  exit 1
fi

public_ip() {
  curl -4fsS --max-time 8 https://api.ipify.org || true
}

resolve_domain() {
  getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true
}

SERVER_IP="$(public_ip)"
DOMAIN_IP="$(resolve_domain)"

if [[ -n "${SERVER_IP}" && -n "${DOMAIN_IP}" && "${SERVER_IP}" != "${DOMAIN_IP}" ]]; then
  cat >&2 <<EOF
Warning: domain IPv4 does not match this VPS public IPv4.
  DOMAIN:    ${DOMAIN}
  DNS IPv4:  ${DOMAIN_IP}
  VPS IPv4:  ${SERVER_IP}

ACME may fail unless DNS has already propagated or this VPS is behind expected NAT.
EOF
fi

echo "== Installing packages =="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ca-certificates gnupg lsb-release unzip tar perl socat cron caddy

echo "== Installing Xray =="
if ! command -v xray >/dev/null 2>&1; then
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
fi

echo "== Preparing firewall hints =="
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi

echo "== Writing TCP tuning =="
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

echo "== Issuing certificate with acme.sh =="
systemctl stop xray 2>/dev/null || true
systemctl stop caddy 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true
systemctl stop lowprint-trojan 2>/dev/null || true

if [[ ! -x /root/.acme.sh/acme.sh ]]; then
  curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"
fi

/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

if [[ ! -f "${TLS_CERT}" || ! -f "${TLS_KEY}" ]]; then
  /root/.acme.sh/acme.sh --issue -d "${DOMAIN}" --standalone --httpport 80 --keylength ec-256
fi

install -d -m 0755 "${CERT_DIR}"
/root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --ecc \
  --fullchain-file "${TLS_CERT}" \
  --key-file "${TLS_KEY}" \
  --reloadcmd "systemctl restart xray >/dev/null 2>&1 || true"

chmod 0644 "${TLS_CERT}"
if id nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1; then
  chgrp nogroup "${TLS_KEY}"
  chmod 0640 "${TLS_KEY}"
else
  chmod 0644 "${TLS_KEY}"
fi

echo "== Writing fallback website =="
install -d -m 0755 "${SITE_ROOT}" /etc/caddy "${STATE_DIR}"
cat > "${SITE_ROOT}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${DOMAIN}</title>
  <style>
    body {
      margin: 0;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: #1f2937;
      background: #f8fafc;
    }
    main {
      max-width: 760px;
      margin: 12vh auto;
      padding: 0 24px;
      line-height: 1.6;
    }
    h1 {
      font-size: 28px;
      font-weight: 650;
      margin: 0 0 12px;
    }
  </style>
</head>
<body>
  <main>
    <h1>${DOMAIN}</h1>
    <p>This site is online.</p>
  </main>
</body>
</html>
EOF

cat > /etc/caddy/Caddyfile <<EOF
{
  email ${EMAIL}
  auto_https off
}

:8080 {
  bind 127.0.0.1
  root * ${SITE_ROOT}
  encode zstd gzip
  file_server
  header {
    -Server
    X-Content-Type-Options nosniff
    Referrer-Policy no-referrer
  }
}
EOF

echo "== Writing Xray config =="
install -d -m 0755 /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-tcp-443",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision",
            "email": "tcp-user"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "${FALLBACK_LISTEN}"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "alpn": [
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "${TLS_CERT}",
              "keyFile": "${TLS_KEY}"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
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
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

SERVER_FOR_CLIENT="${SERVER_IP:-${DOMAIN}}"

cat > "${STATE_DIR}/client-sing-box.json" <<EOF
{
  "log": {
    "level": "warn"
  },
  "dns": {
    "servers": [
      {
        "tag": "remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "vless-tcp"
      },
      {
        "tag": "local",
        "address": "local"
      }
    ],
    "rules": [
      {
        "geosite": "cn",
        "server": "local"
      }
    ],
    "final": "remote"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": ${CLIENT_MIXED_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-tcp",
      "server": "${SERVER_FOR_CLIENT}",
      "server_port": 443,
      "uuid": "${VLESS_UUID}",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "geosite": "cn",
        "geoip": [
          "cn",
          "private"
        ],
        "outbound": "direct"
      }
    ],
    "final": "vless-tcp",
    "auto_detect_interface": true
  }
}
EOF

cat > "${STATE_DIR}/client-links.txt" <<EOF
vless://${VLESS_UUID}@${SERVER_FOR_CLIENT}:443?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp#vless-tcp
EOF

cat > "${STATE_DIR}/server.env" <<EOF
DOMAIN=${DOMAIN}
SERVER_IP=${SERVER_FOR_CLIENT}
CONTACT_EMAIL=${EMAIL}
TLS_CERT=${TLS_CERT}
TLS_KEY=${TLS_KEY}
VLESS_UUID=${VLESS_UUID}
FALLBACK_LISTEN=${FALLBACK_LISTEN}
SITE_ROOT=${SITE_ROOT}
CLIENT_MIXED_PORT=${CLIENT_MIXED_PORT}
EOF

echo "== Starting services =="
systemctl enable caddy
systemctl restart caddy
systemctl enable xray
systemctl restart xray

if systemctl list-unit-files hysteria-server.service >/dev/null 2>&1; then
  systemctl disable --now hysteria-server || true
fi

if systemctl list-unit-files lowprint-trojan.service >/dev/null 2>&1; then
  systemctl disable --now lowprint-trojan || true
fi

echo "== Verification =="
systemctl --no-pager --lines=0 status caddy xray || true
echo
echo "Public HTTPS fallback check:"
curl -I --resolve "${DOMAIN}:443:${SERVER_FOR_CLIENT}" "https://${DOMAIN}/" --max-time 10 || true
echo
echo "Installed TCP-only line."
echo "Domain: ${DOMAIN}"
echo "UUID: ${VLESS_UUID}"
echo "Client link:"
cat "${STATE_DIR}/client-links.txt"
echo
echo "Client sing-box config: ${STATE_DIR}/client-sing-box.json"
echo "Server env: ${STATE_DIR}/server.env"
