#!/usr/bin/env bash
set -euo pipefail

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
STATE_FILE="/etc/vless-reality-vision-minimal.env"

ACTION="install"
PORT="443"
UUID_VALUE=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SNI="www.cloudflare.com"
DEST="www.cloudflare.com:443"
SERVER_ADDR=""
NAME="vless-reality-vision"
SELF_TEST="1"
SELF_TEST_URL="https://www.gstatic.com/generate_204"

usage() {
  cat <<'EOF'
Minimal VLESS + REALITY + TCP/RAW + Vision installer.

Core idea:
  VLESS   = lightweight proxy protocol
  REALITY = TLS-like security/camouflage without owning a domain
  RAW/TCP = minimal transport overhead
  Vision  = TCP performance flow control

Usage:
  sudo bash vless-reality-vision-minimal.sh install [options]
  sudo bash vless-reality-vision-minimal.sh show [--server SERVER_IP_OR_DOMAIN]
  sudo bash vless-reality-vision-minimal.sh status
  sudo bash vless-reality-vision-minimal.sh self-test [--server SERVER_IP_OR_DOMAIN]
  sudo bash vless-reality-vision-minimal.sh uninstall

Install options:
  --port 443
  --id UUID
  --private-key REALITY_PRIVATE_KEY
  --short-id HEX_SHORT_ID
  --sni www.cloudflare.com
  --dest www.cloudflare.com:443
  --server SERVER_IP_OR_DOMAIN
  --name NODE_NAME
  --skip-self-test
  --self-test-url https://www.gstatic.com/generate_204

Examples:
  sudo bash vless-reality-vision-minimal.sh install --server 38.54.82.45

  sudo bash vless-reality-vision-minimal.sh install \
    --port 443 \
    --sni www.cloudflare.com \
    --dest www.cloudflare.com:443 \
    --server 38.54.82.45

Notes:
  - Open TCP port 443 in your VPS/cloud firewall.
  - Use the "type=tcp" link first for older clients.
  - Use the "type=raw" link only if the client explicitly supports raw.
  - The default REALITY target is Cloudflare. Microsoft is avoided because
    recent Xray/REALITY versions can fail the handshake with that target.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  [[ "$(id -u)" == "0" ]] || die "run as root or with sudo"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_base_tools() {
  if have_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl procps
  elif have_cmd dnf; then
    dnf install -y curl ca-certificates openssl procps-ng
  elif have_cmd yum; then
    yum install -y curl ca-certificates openssl procps-ng
  else
    die "unsupported package manager; install curl, ca-certificates, openssl manually"
  fi
}

install_xray() {
  if [[ -x "$XRAY_BIN" ]]; then
    return
  fi
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

enable_tcp_tuning() {
  cat >/etc/sysctl.d/99-vless-reality-vision.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=4
EOF
  sysctl --system >/dev/null || true
}

gen_uuid() {
  if [[ -n "$UUID_VALUE" ]]; then
    echo "$UUID_VALUE"
  else
    "$XRAY_BIN" uuid
  fi
}

gen_short_id() {
  if [[ -n "$SHORT_ID" ]]; then
    echo "$SHORT_ID"
  else
    openssl rand -hex 8
  fi
}

gen_reality_keys() {
  if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
    return
  fi
  local pair
  pair="$("$XRAY_BIN" x25519)"
  PRIVATE_KEY="$(printf '%s\n' "$pair" | awk -F': ' '/PrivateKey:|Private key:/ {print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "$pair" | awk -F': ' '/Password \(PublicKey\):|Public key:/ {print $2; exit}')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "failed to generate REALITY keys"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

urlencode() {
  local raw="$1"
  local length="${#raw}"
  local i char out=""
  for ((i = 0; i < length; i++)); do
    char="${raw:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) out+="$char" ;;
      *) printf -v out '%s%%%02X' "$out" "'$char" ;;
    esac
  done
  printf '%s' "$out"
}

detect_public_ip() {
  if [[ -n "$SERVER_ADDR" ]]; then
    echo "$SERVER_ADDR"
    return
  fi
  local ip=""
  ip="$(curl -4fsS --max-time 6 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 6 https://ifconfig.me || true)"
  fi
  echo "$ip"
}

warn_risky_reality_target() {
  case "$SNI:$DEST" in
    *www.microsoft.com*|*microsoft.com*)
      cat >&2 <<'EOF'
WARNING: www.microsoft.com is a known risky REALITY target on recent Xray
versions and may cause "handshake did not complete successfully".
Prefer the default www.cloudflare.com unless you have tested this target.
EOF
      ;;
  esac
}

write_config() {
  local id short_id private_key public_key sni dest
  id="$(gen_uuid)"
  gen_reality_keys
  private_key="$PRIVATE_KEY"
  public_key="$PUBLIC_KEY"
  short_id="$(gen_short_id)"
  sni="$(json_escape "$SNI")"
  dest="$(json_escape "$DEST")"

  mkdir -p "$(dirname "$XRAY_CONFIG")"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$id",
            "flow": "xtls-rprx-vision",
            "email": "vision@minimal"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$dest",
          "xver": 0,
          "serverNames": ["$sni"],
          "privateKey": "$private_key",
          "shortIds": ["$short_id"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

  cat >"$STATE_FILE" <<EOF
PORT='$PORT'
UUID_VALUE='$id'
PRIVATE_KEY='$private_key'
PUBLIC_KEY='$public_key'
SHORT_ID='$short_id'
SNI='$SNI'
DEST='$DEST'
NAME='$NAME'
EOF

  chmod 600 "$STATE_FILE"
}

test_and_restart_xray() {
  "$XRAY_BIN" run -test -c "$XRAY_CONFIG"
  systemctl enable --now xray >/dev/null
  systemctl restart xray
}

run_self_test() {
  [[ -f "$STATE_FILE" ]] || die "state file not found; run install first"
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  local server test_config test_log client_pid socks_port status
  server="$(detect_public_ip)"
  [[ -n "$server" ]] || die "cannot determine server address; rerun with --server SERVER_IP_OR_DOMAIN"

  socks_port="19080"
  test_config="$(mktemp /tmp/vless-reality-selftest.XXXXXX.json)"
  test_log="$(mktemp /tmp/vless-reality-selftest.XXXXXX.log)"
  client_pid=""

  cat >"$test_config" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks",
      "listen": "127.0.0.1",
      "port": $socks_port,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$server",
            "port": $PORT,
            "users": [
              {
                "id": "$UUID_VALUE",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "$SNI",
          "publicKey": "$PUBLIC_KEY",
          "shortId": "$SHORT_ID",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF

  "$XRAY_BIN" run -test -c "$test_config" >/dev/null
  "$XRAY_BIN" run -c "$test_config" >"$test_log" 2>&1 &
  client_pid="$!"
  sleep 3

  set +e
  curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:$socks_port" \
    "$SELF_TEST_URL" -o /tmp/vless-reality-selftest.out
  status="$?"
  set -e

  kill "$client_pid" >/dev/null 2>&1 || true
  wait "$client_pid" >/dev/null 2>&1 || true

  if [[ "$status" != "0" ]]; then
    echo "ERROR: self-test failed. The server is installed, but the VLESS/REALITY handshake did not pass." >&2
    echo "Most likely causes: bad SNI/dest pair, unsupported client transport, firewall, or REALITY target incompatibility." >&2
    echo "Current SNI: $SNI" >&2
    echo "Current dest: $DEST" >&2
    echo "Client test log:" >&2
    tail -80 "$test_log" >&2 || true
    rm -f "$test_config" "$test_log"
    return 1
  fi

  rm -f "$test_config" "$test_log"
  echo "self-test passed: VLESS/REALITY/Vision tunnel can reach $SELF_TEST_URL"
}

print_links() {
  [[ -f "$STATE_FILE" ]] || die "state file not found; run install first"
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  local server label encoded_name encoded_sni encoded_spx tcp_link raw_link
  server="$(detect_public_ip)"
  [[ -n "$server" ]] || server="SERVER_IP_OR_DOMAIN"
  label="${NAME}-${server}"
  encoded_name="$(urlencode "$label")"
  encoded_sni="$(urlencode "$SNI")"
  encoded_spx="$(urlencode "/")"

  tcp_link="vless://${UUID_VALUE}@${server}:${PORT}?encryption=none&security=reality&sni=${encoded_sni}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&spx=${encoded_spx}#${encoded_name}"
  raw_link="vless://${UUID_VALUE}@${server}:${PORT}?encryption=none&security=reality&sni=${encoded_sni}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=raw&flow=xtls-rprx-vision&spx=${encoded_spx}#${encoded_name}-raw"

  cat <<EOF
VLESS + REALITY + TCP/RAW + Vision is ready.

Server:
  address:   $server
  port:      $PORT
  uuid:      $UUID_VALUE
  publicKey: $PUBLIC_KEY
  shortId:   $SHORT_ID
  sni:       $SNI
  dest:      $DEST
  flow:      xtls-rprx-vision

Import link for most clients:
$tcp_link

Import link for newer Xray clients:
$raw_link
EOF
}

show_status() {
  systemctl is-active xray || true
  ss -lntp | grep -E ":${PORT}[[:space:]]" || true
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc || true
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    echo "sni = $SNI"
    echo "dest = $DEST"
  fi
}

uninstall() {
  systemctl disable --now xray >/dev/null 2>&1 || true
  rm -f "$XRAY_CONFIG" "$STATE_FILE" /etc/sysctl.d/99-vless-reality-vision.conf
  echo "removed minimal VLESS config and state; Xray binary/package was left installed"
}

parse_args() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ $# -gt 0 ]]; then
    ACTION="$1"
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) PORT="$2"; shift 2 ;;
      --id|--uuid) UUID_VALUE="$2"; shift 2 ;;
      --private-key) PRIVATE_KEY="$2"; shift 2 ;;
      --public-key) PUBLIC_KEY="$2"; shift 2 ;;
      --short-id) SHORT_ID="$2"; shift 2 ;;
      --sni) SNI="$2"; shift 2 ;;
      --dest) DEST="$2"; shift 2 ;;
      --server) SERVER_ADDR="$2"; shift 2 ;;
      --name) NAME="$2"; shift 2 ;;
      --skip-self-test) SELF_TEST="0"; shift ;;
      --self-test-url) SELF_TEST_URL="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  case "$ACTION" in
    install)
      need_root
      install_base_tools
      install_xray
      enable_tcp_tuning
      warn_risky_reality_target
      write_config
      test_and_restart_xray
      if [[ "$SELF_TEST" == "1" ]]; then
        run_self_test
      fi
      print_links
      ;;
    show)
      print_links
      ;;
    status)
      show_status
      ;;
    self-test)
      need_root
      run_self_test
      ;;
    uninstall)
      need_root
      uninstall
      ;;
    *)
      usage
      die "unknown action: $ACTION"
      ;;
  esac
}

main "$@"
