#!/usr/bin/env bash
# Single-hop VLESS + RAW/TCP + REALITY + XTLS Vision installer.
# It never executes downloaded shell code and never replaces xray.service.

set -Eeuo pipefail
umask 077

readonly SERVICE="x420-vless.service"
readonly SERVICE_USER="x420-xray"
readonly ROOT_DIR="/etc/x420-vless"
readonly CONFIG="$ROOT_DIR/config.json"
readonly CREDS="$ROOT_DIR/credentials.json"
readonly STATE="$ROOT_DIR/state.env"
readonly UNIT="/etc/systemd/system/$SERVICE"
readonly BIN_DIR="/usr/local/lib/x420-vless"
readonly BIN="$BIN_DIR/xray"
readonly LOCK_FILE="/run/lock/x420-vless.lock"
readonly PERFORMANCE_FILE="/etc/sysctl.d/70-x420-vless-performance.conf"
readonly PERFORMANCE_STATE="$ROOT_DIR/network-tune.env"

MODE=""
SERVER=""
SNI=""
TARGET=""
PORT="443"
NAME="x420-client"
UUID=""
SHORT_ID=""
VERSION=""
SHA256=""
ARCHIVE=""
YES="0"
HEALTH_URL="https://www.gstatic.com/generate_204"
TUNE_ACTION=""
STAGE=""
INSTALLING="0"
COMMITTED="0"
UPGRADING="0"
UPGRADE_BACKUP=""

log() { printf '%s\n' "==> $*"; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash x420-vless-low-redundancy.sh install \
    --server IPv4 --sni HOST --target HOST:PORT \
    --xray-version TAG --xray-sha256 SHA256 [--port PORT]

  sudo bash x420-vless-low-redundancy.sh install \
    --server IPv4 --sni HOST --target HOST:PORT \
    --xray-archive FILE --xray-sha256 SHA256 [--port PORT]

  sudo bash x420-vless-low-redundancy.sh verify
  sudo bash x420-vless-low-redundancy.sh healthcheck [--health-url HTTPS_URL]
  sudo bash x420-vless-low-redundancy.sh upgrade \
    --xray-version TAG --xray-sha256 SHA256
  sudo bash x420-vless-low-redundancy.sh status
  sudo bash x420-vless-low-redundancy.sh network-tune status
  sudo bash x420-vless-low-redundancy.sh network-tune apply --yes
  sudo bash x420-vless-low-redundancy.sh network-tune rollback --yes
  sudo bash x420-vless-low-redundancy.sh show-credentials
  sudo bash x420-vless-low-redundancy.sh uninstall --yes

Design:
  client -> VLESS + RAW/TCP + REALITY + XTLS Vision -> one VPS -> direct egress

The install command requires a pinned Xray release tag plus a SHA-256 obtained
from an independent trusted channel, or a locally staged archive plus its hash.
No package, firewall, sysctl, or existing xray.service is modified during install.
network-tune is an explicit, reversible BBR + FQ setting for a dedicated VPS;
it changes global TCP defaults and therefore requires --yes. The server endpoint
is deliberately IPv4-only; do not publish an AAAA record for it.
EOF
}

cleanup() {
  if [[ -n $STAGE && -d $STAGE ]]; then
    rm -rf -- "$STAGE"
  fi
  return 0
}
trap cleanup EXIT

rollback() {
  set +e
  systemctl disable --now "$SERVICE" >/dev/null 2>&1
  rm -f -- "$UNIT" "$CONFIG" "$CREDS" "$STATE" "$BIN"
  rmdir --ignore-fail-on-non-empty "$ROOT_DIR" "$BIN_DIR" >/dev/null 2>&1
  systemctl daemon-reload >/dev/null 2>&1
  set -e
}

abort_install() {
  rollback
  INSTALLING="0"
  die "$1"
}

on_error() {
  local rc="$?"
  if [[ $UPGRADING == "1" && -n $UPGRADE_BACKUP && -x $UPGRADE_BACKUP ]]; then
    printf '%s\n' "ERROR: Upgrade failed; restoring the previous Xray binary." >&2
    install -m 0755 "$UPGRADE_BACKUP" "$BIN" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  elif [[ $INSTALLING == "1" && $COMMITTED != "1" ]]; then
    printf '%s\n' "ERROR: Install failed; rolling back x420-owned artifacts." >&2
    rollback
  fi
  exit "$rc"
}
trap on_error ERR

need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

acquire_lock() {
  need_cmd flock
  install -d -m 0755 /run/lock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another x420 installation, upgrade, or uninstall is already running."
}

valid_host() {
  local length
  length="$(printf '%s' "$1" | wc -c)"
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
    [[ $1 != *..* ]] && [[ $length -le 253 ]]
}

valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_ipv4() {
  [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  awk -F. '$1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 { exit 0 } { exit 1 }' <<<"$1"
}

parse_args() {
  (( $# > 0 )) || { usage; exit 0; }
  [[ $1 != "--help" && $1 != "-h" ]] || { usage; exit 0; }
  MODE="$1"
  shift
  if [[ $MODE == "network-tune" && $# -gt 0 && $1 != --* ]]; then
    TUNE_ACTION="$1"
    shift
  fi
  while (( $# > 0 )); do
    case "$1" in
      --server|--sni|--target|--port|--client-name|--uuid|--short-id|--xray-version|--xray-sha256|--xray-archive|--health-url)
        (( $# >= 2 )) || die "Missing value for $1"
        case "$1" in
          --server) SERVER="$2" ;;
          --sni) SNI="$2" ;;
          --target) TARGET="$2" ;;
          --port) PORT="$2" ;;
          --client-name) NAME="$2" ;;
          --uuid) UUID="$2" ;;
          --short-id) SHORT_ID="$2" ;;
          --xray-version) VERSION="$2" ;;
          --xray-sha256) SHA256="$2" ;;
          --xray-archive) ARCHIVE="$2" ;;
          --health-url) HEALTH_URL="$2" ;;
        esac
        shift 2
        ;;
      --yes) YES="1"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

target_host() { printf '%s' "$1" | sed 's/:[^:]*$//'; }
target_port() { printf '%s' "$1" | sed 's/^.*://'; }

validate_install() {
  local target_name target_number short_length
  [[ -n $SERVER && -n $SNI && -n $TARGET && -n $SHA256 ]] ||
    die "install needs --server, --sni, --target, and --xray-sha256."
  valid_ipv4 "$SERVER" || die "--server must be a public IPv4 address; IPv6 and hostnames are intentionally unsupported."
  valid_host "$SNI" || die "--sni is invalid."
  target_name="$(target_host "$TARGET")"
  target_number="$(target_port "$TARGET")"
  valid_host "$target_name" && valid_port "$target_number" ||
    die "--target must be HOST:PORT; IPv6 literals are unsupported."
  valid_port "$PORT" || die "--port must be 1-65535."
  [[ $NAME =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "--client-name is invalid."
  [[ $SHA256 =~ ^[A-Fa-f0-9]{64}$ ]] || die "--xray-sha256 must have 64 hex characters."
  [[ -z $UUID || $UUID =~ ^[A-Fa-f0-9-]{36}$ ]] || die "--uuid is invalid."
  [[ -z $SHORT_ID || $SHORT_ID =~ ^[A-Fa-f0-9]{2,16}$ ]] || die "--short-id is invalid."
  if [[ -n $SHORT_ID ]]; then
    short_length="$(printf '%s' "$SHORT_ID" | wc -c)"
    (( short_length % 2 == 0 )) || die "--short-id length must be even."
  fi
  if [[ -n $ARCHIVE ]]; then
    [[ -r $ARCHIVE && -z $VERSION ]] ||
      die "--xray-archive must be readable and cannot be combined with --xray-version."
  else
    [[ $VERSION =~ ^v[0-9][A-Za-z0-9._-]*$ ]] ||
      die "--xray-version must be a pinned tag such as vX.Y.Z."
  fi
}

assert_linux_commands() {
  [[ $(uname -s) == "Linux" ]] || die "Linux is required."
  need_cmd systemctl
  local cmd
  for cmd in curl unzip openssl sha256sum ss install awk grep sed tr id getent groupadd useradd flock timeout sleep sysctl; do need_cmd "$cmd"; done
}

assert_clean_host() {
  assert_linux_commands
  [[ ! -e $ROOT_DIR && ! -e $UNIT && ! -e $BIN ]] ||
    die "An x420 installation artifact exists; refusing to overwrite it."
  if ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
    die "TCP port $PORT is already in use."
  fi
}

asset_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "Xray-linux-64.zip" ;;
    aarch64|arm64) printf '%s\n' "Xray-linux-arm64-v8a.zip" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

install_xray() {
  local archive expected actual url
  archive="$STAGE/xray.zip"
  if [[ -n $ARCHIVE ]]; then
    install -m 0600 "$ARCHIVE" "$archive"
  else
    url="https://github.com/XTLS/Xray-core/releases/download/$VERSION/$(asset_name)"
    log "Downloading pinned Xray release $VERSION."
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$archive"
  fi
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  expected="$(printf '%s' "$SHA256" | tr 'A-F' 'a-f')"
  [[ $actual == "$expected" ]] || abort_install "Xray archive SHA-256 mismatch."
  unzip -q "$archive" -d "$STAGE/xray"
  [[ -x $STAGE/xray/xray ]] || abort_install "The archive does not contain an xray binary."
  install -d -m 0755 "$BIN_DIR"
  install -m 0755 "$STAGE/xray/xray" "$BIN"
}

validate_upgrade_source() {
  [[ -n $SHA256 ]] || die "upgrade needs --xray-sha256."
  [[ $SHA256 =~ ^[A-Fa-f0-9]{64}$ ]] || die "--xray-sha256 must have 64 hex characters."
  [[ -z $ARCHIVE ]] || die "upgrade currently accepts only a pinned release download."
  [[ $VERSION =~ ^v[0-9][A-Za-z0-9._-]*$ ]] ||
    die "upgrade needs --xray-version in pinned tag form, such as vX.Y.Z."
}

upgrade() {
  local archive actual expected url
  need_root
  acquire_lock
  [[ -x $BIN && -r $CONFIG ]] || die "No x420 installation found."
  assert_linux_commands
  validate_upgrade_source
  STAGE="$(mktemp -d /tmp/x420-vless-upgrade.XXXXXX)"
  archive="$STAGE/xray.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/$VERSION/$(asset_name)"
  log "Downloading pinned Xray release $VERSION for upgrade."
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$archive"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  expected="$(printf '%s' "$SHA256" | tr 'A-F' 'a-f')"
  [[ $actual == "$expected" ]] || die "Xray archive SHA-256 mismatch."
  unzip -q "$archive" -d "$STAGE/xray"
  [[ -x $STAGE/xray/xray ]] || die "The archive does not contain an xray binary."
  "$STAGE/xray/xray" run -test -config "$CONFIG" ||
    die "The new Xray binary rejected the existing configuration."

  UPGRADING="1"
  install -m 0755 "$BIN" "$STAGE/xray.previous"
  UPGRADE_BACKUP="$STAGE/xray.previous"
  install -m 0755 "$STAGE/xray/xray" "$BIN"
  if "$BIN" run -test -config "$CONFIG" && systemctl restart "$SERVICE" &&
    systemctl is-active --quiet "$SERVICE"; then
    UPGRADING="0"
    log "Upgrade complete. Run healthcheck after confirming external firewall reachability."
    return
  fi

  printf '%s\n' "ERROR: Upgrade failed; restoring the previous Xray binary." >&2
  install -m 0755 "$STAGE/xray.previous" "$BIN"
  systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  UPGRADING="0"
  die "Upgrade rolled back."
}

ensure_service_identity() {
  if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
    groupadd --system "$SERVICE_USER" || abort_install "Unable to create the service group."
  fi
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_USER" --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER" ||
      abort_install "Unable to create the service user."
  fi
}

write_candidates() {
  local pair private_key public_key uri
  [[ -n $UUID ]] || UUID="$("$BIN" uuid)"
  [[ $UUID =~ ^[A-Fa-f0-9-]{36}$ ]] || abort_install "Xray returned an invalid UUID."
  [[ -n $SHORT_ID ]] || SHORT_ID="$(openssl rand -hex 8)"
  pair="$("$BIN" x25519)"
  private_key="$(awk -F': ' '/^PrivateKey:|^Private key:/ {print $2; exit}' <<<"$pair")"
  public_key="$(awk -F': ' '/^Password \(PublicKey\):|^Public key:/ {print $2; exit}' <<<"$pair")"
  [[ -n $private_key && -n $public_key ]] || abort_install "Unable to generate REALITY keys."

  log "Checking the REALITY target TLS handshake."
  timeout 15 "$BIN" tls ping "$TARGET" >/dev/null ||
    abort_install "The target TLS handshake failed or timed out from this VPS."

  cat >"$STAGE/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "vless-reality-in",
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "email": "$NAME", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "$TARGET",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$private_key",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "tag": "direct", "protocol": "freedom" }]
}
EOF

  uri="vless://$UUID@$SERVER:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$public_key&sid=$SHORT_ID&type=raw&headerType=none#$NAME"
  cat >"$STAGE/credentials.json" <<EOF
{
  "server": "$SERVER",
  "port": $PORT,
  "uuid": "$UUID",
  "flow": "xtls-rprx-vision",
  "transport": "raw",
  "security": "reality",
  "sni": "$SNI",
  "target": "$TARGET",
  "fingerprint": "chrome",
  "publicKey": "$public_key",
  "shortId": "$SHORT_ID",
  "uri": "$uri"
}
EOF

  cat >"$STAGE/state.env" <<EOF
server=$SERVER
port=$PORT
sni=$SNI
uuid=$UUID
short_id=$SHORT_ID
public_key=$public_key
EOF

  cat >"$STAGE/$SERVICE" <<EOF
[Unit]
Description=x420 VLESS + REALITY service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN run -config $CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
}

commit_install() {
  local attempt
  "$BIN" run -test -config "$STAGE/config.json"
  install -d -m 0750 -o root -g "$SERVICE_USER" "$ROOT_DIR"
  install -m 0640 -o root -g "$SERVICE_USER" "$STAGE/config.json" "$CONFIG"
  install -m 0600 -o root -g root "$STAGE/credentials.json" "$CREDS"
  install -m 0600 -o root -g root "$STAGE/state.env" "$STATE"
  install -m 0644 "$STAGE/$SERVICE" "$UNIT"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE" || abort_install "Service start failed."
  systemctl is-active --quiet "$SERVICE" || abort_install "Service did not remain active."
  attempt=0
  while (( attempt < 20 )); do
    if ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
      return
    fi
    sleep 0.25
    attempt="$((attempt + 1))"
  done
  abort_install "Service is active but TCP port $PORT did not begin listening."
}

install_all() {
  need_root
  acquire_lock
  validate_install
  assert_clean_host
  INSTALLING="1"
  STAGE="$(mktemp -d /tmp/x420-vless.XXXXXX)"
  install_xray
  ensure_service_identity
  write_candidates
  commit_install
  COMMITTED="1"
  log "Installed. Open TCP/$PORT in your external firewall or security group if needed."
  log "Credentials are root-only: $CREDS"
}

verify() {
  need_root
  [[ -x $BIN && -r $CONFIG ]] || die "No x420 installation found."
  "$BIN" run -test -config "$CONFIG"
  systemctl is-active --quiet "$SERVICE" || die "$SERVICE is inactive."
  log "Configuration and service verification passed."
}

load_state() {
  local key value
  H_SERVER=""
  H_PORT=""
  H_SNI=""
  H_UUID=""
  H_SHORT_ID=""
  H_PUBLIC_KEY=""
  [[ -r $STATE ]] || die "No x420 state file found."
  while IFS='=' read -r key value; do
    case "$key" in
      server) H_SERVER="$value" ;;
      port) H_PORT="$value" ;;
      sni) H_SNI="$value" ;;
      uuid) H_UUID="$value" ;;
      short_id) H_SHORT_ID="$value" ;;
      public_key) H_PUBLIC_KEY="$value" ;;
    esac
  done <"$STATE"
  valid_ipv4 "$H_SERVER" && valid_port "$H_PORT" && valid_host "$H_SNI" ||
    die "The x420 state file is invalid."
  [[ $H_UUID =~ ^[A-Fa-f0-9-]{36}$ && $H_SHORT_ID =~ ^[A-Fa-f0-9]{2,16}$ ]] ||
    die "The x420 state file contains invalid credentials."
}

healthcheck() {
  local temp_dir socks_port attempt ready pid status
  need_root
  [[ $HEALTH_URL =~ ^https://[^[:space:]]+$ ]] || die "--health-url must be an HTTPS URL without whitespace."
  [[ -x $BIN ]] || die "No x420 installation found."
  load_state
  temp_dir="$(mktemp -d /tmp/x420-vless-health.XXXXXX)"
  socks_port=""
  attempt=0
  while (( attempt < 20 )); do
    ready="$((20000 + RANDOM % 20000))"
    if ! ss -ltnH "sport = :$ready" 2>/dev/null | grep -q .; then
      socks_port="$ready"
      break
    fi
    attempt="$((attempt + 1))"
  done
  [[ -n $socks_port ]] || { rm -rf -- "$temp_dir"; die "Unable to reserve a local SOCKS port."; }

  cat >"$temp_dir/client.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": $socks_port,
    "protocol": "socks",
    "settings": { "udp": false }
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$H_SERVER",
        "port": $H_PORT,
        "users": [{ "id": "$H_UUID", "encryption": "none", "flow": "xtls-rprx-vision" }]
      }]
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "serverName": "$H_SNI",
        "fingerprint": "chrome",
        "password": "$H_PUBLIC_KEY",
        "shortId": "$H_SHORT_ID"
      }
    }
  }]
}
EOF

  "$BIN" run -test -config "$temp_dir/client.json" || { rm -rf -- "$temp_dir"; die "Healthcheck client configuration is invalid."; }
  "$BIN" run -config "$temp_dir/client.json" >"$temp_dir/client.log" 2>&1 &
  pid="$!"
  ready="0"
  attempt=0
  while (( attempt < 20 )); do
    if ss -ltnH "sport = :$socks_port" 2>/dev/null | grep -q .; then
      ready="1"
      break
    fi
    sleep 0.25
    attempt="$((attempt + 1))"
  done
  if [[ $ready != "1" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    tail -50 "$temp_dir/client.log" >&2 || true
    rm -rf -- "$temp_dir"
    die "Healthcheck client did not start."
  fi

  set +e
  curl --fail --silent --show-error --location --max-time 20 \
    --socks5-hostname "127.0.0.1:$socks_port" "$HEALTH_URL" -o /dev/null
  status="$?"
  set -e
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  if [[ $status != "0" ]]; then
    tail -50 "$temp_dir/client.log" >&2 || true
    rm -rf -- "$temp_dir"
    die "End-to-end healthcheck failed."
  fi
  rm -rf -- "$temp_dir"
  log "End-to-end VLESS healthcheck passed: $HEALTH_URL"
}

network_tune_status() {
  local qdisc congestion available ownership
  need_cmd sysctl
  qdisc="$(sysctl -n net.core.default_qdisc)"
  congestion="$(sysctl -n net.ipv4.tcp_congestion_control)"
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
  ownership="unmanaged"
  [[ -r $PERFORMANCE_STATE ]] && ownership="managed-by-x420"
  printf '%s\n' "TCP queue discipline: $qdisc"
  printf '%s\n' "TCP congestion control: $congestion"
  printf '%s\n' "Available congestion controls: $available"
  printf '%s\n' "Performance tuning ownership: $ownership"
  if [[ $qdisc == "fq" && $congestion == "bbr" ]]; then
    log "The BBR + FQ runtime target is active."
  else
    log "The BBR + FQ runtime target is not active."
  fi
}

assert_bbr_supported() {
  sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -qx 'bbr' ||
    die "This kernel does not advertise BBR support."
}

load_performance_state() {
  local key value
  PREVIOUS_QDISC=""
  PREVIOUS_CONGESTION=""
  [[ -r $PERFORMANCE_STATE ]] || die "No x420-managed network-tune state exists."
  while IFS='=' read -r key value; do
    case "$key" in
      previous_qdisc) PREVIOUS_QDISC="$value" ;;
      previous_congestion) PREVIOUS_CONGESTION="$value" ;;
    esac
  done <"$PERFORMANCE_STATE"
  [[ $PREVIOUS_QDISC =~ ^[A-Za-z0-9_-]+$ && $PREVIOUS_CONGESTION =~ ^[A-Za-z0-9_-]+$ ]] ||
    die "The network-tune state file is invalid."
}

apply_network_tune() {
  local qdisc congestion stage
  need_root
  acquire_lock
  [[ $YES == "1" ]] || die "network-tune apply requires --yes."
  [[ -x $BIN && -r $CONFIG ]] || die "No x420 installation found."
  need_cmd sysctl
  need_cmd install
  assert_bbr_supported
  qdisc="$(sysctl -n net.core.default_qdisc)"
  congestion="$(sysctl -n net.ipv4.tcp_congestion_control)"
  if [[ $qdisc == "fq" && $congestion == "bbr" ]]; then
    log "BBR + FQ is already active; leaving existing system tuning unmanaged."
    return
  fi
  [[ ! -e $PERFORMANCE_STATE && ! -e $PERFORMANCE_FILE ]] ||
    die "An x420 network-tune artifact already exists; use rollback first."
  stage="$(mktemp -d /tmp/x420-vless-network.XXXXXX)"
  printf 'previous_qdisc=%s\nprevious_congestion=%s\n' "$qdisc" "$congestion" >"$stage/state.env"
  cat >"$stage/70-x420-vless-performance.conf" <<'EOF'
# Explicit x420 performance setting for a dedicated single-VPS deployment.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  if ! sysctl -w net.core.default_qdisc=fq >/dev/null ||
    ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null; then
    sysctl -w "net.core.default_qdisc=$qdisc" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.tcp_congestion_control=$congestion" >/dev/null 2>&1 || true
    rm -rf -- "$stage"
    die "Unable to activate BBR + FQ; previous runtime values were restored."
  fi
  install -m 0600 "$stage/state.env" "$PERFORMANCE_STATE"
  install -m 0644 "$stage/70-x420-vless-performance.conf" "$PERFORMANCE_FILE"
  rm -rf -- "$stage"
  log "BBR + FQ activated and recorded for rollback. Existing TCP connections keep their current settings."
}

rollback_network_tune() {
  need_root
  need_cmd sysctl
  load_performance_state
  if ! sysctl -w "net.core.default_qdisc=$PREVIOUS_QDISC" >/dev/null ||
    ! sysctl -w "net.ipv4.tcp_congestion_control=$PREVIOUS_CONGESTION" >/dev/null; then
    die "Unable to restore the previous runtime TCP settings; kept the rollback files."
  fi
  rm -f -- "$PERFORMANCE_FILE" "$PERFORMANCE_STATE"
  log "Restored the TCP settings that existed before x420 network-tune."
}

network_tune() {
  case "$TUNE_ACTION" in
    status) network_tune_status ;;
    apply) apply_network_tune ;;
    rollback)
      need_root
      acquire_lock
      [[ $YES == "1" ]] || die "network-tune rollback requires --yes."
      rollback_network_tune
      ;;
    *) die "Use network-tune status, network-tune apply --yes, or network-tune rollback --yes." ;;
  esac
}

status() {
  systemctl --no-pager --full status "$SERVICE" 2>/dev/null || true
  [[ -r $CONFIG ]] && grep -E '"port"|"network"|"security"|"target"' "$CONFIG" || true
  [[ -x $BIN ]] && network_tune_status || true
}

show_credentials() {
  need_root
  [[ -r $CREDS ]] || die "No x420 credentials found."
  cat "$CREDS"
}

uninstall() {
  need_root
  acquire_lock
  [[ $YES == "1" ]] || die "uninstall requires --yes."
  [[ -r $PERFORMANCE_STATE ]] && rollback_network_tune
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f -- "$UNIT" "$CONFIG" "$CREDS" "$STATE" "$BIN" "$PERFORMANCE_FILE"
  rmdir --ignore-fail-on-non-empty "$ROOT_DIR" "$BIN_DIR" >/dev/null 2>&1 || true
  systemctl daemon-reload
  log "Removed only x420-owned files."
}

main() {
  parse_args "$@"
  case "$MODE" in
    install) install_all ;;
    verify) verify ;;
    healthcheck) healthcheck ;;
    upgrade) upgrade ;;
    status) status ;;
    network-tune) network_tune ;;
    show-credentials) show_credentials ;;
    uninstall) uninstall ;;
    *) usage; die "Use install, verify, status, show-credentials, or uninstall." ;;
  esac
}

main "$@"
