#!/usr/bin/env bash
set -Eeuo pipefail

# Physics-first single VPS landing script.
# Model:
#   shortest path:      Client -> VLESS/TCP/REALITY/Vision -> VPS -> Target
#   least media loss:   no CDN, no WS, no gRPC, no multi-hop
#   steady state:       long idle window + active TCP keepalive
#   fast recovery:      TCP user timeout + systemd restart + QUIC fallback to TCP

PORT="${XRAY_PORT:-443}"
SNI="${REALITY_SNI:-www.cloudflare.com}"
DEST="${REALITY_DEST:-www.cloudflare.com:443}"
SERVER_ADDR="${SERVER_ADDR:-}"
PURGE_OLD=1
ENABLE_BBR=1
OPEN_FIREWALL=1
INSTALL_XRAY=1
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/ericyiu9819/x420/main/install-vless-reality.sh}"

usage() {
  cat <<'EOF'
Usage:
  bash install-physics-vless-single.sh [options]

Options:
  --port <port>              Listen TCP port. Default: 443
  --server <domain_or_ip>    Address shown in client link. Auto-detected if omitted.
  --sni <domain>             REALITY serverName. Default: www.cloudflare.com
  --dest <host:port>         REALITY dest. Default: www.cloudflare.com:443
  --keep-old                 Do not purge old Xray config/drop-ins.
  --no-bbr                   Do not apply TCP/BBR tuning.
  --no-firewall              Do not open firewall port.
  --no-install               Do not install/upgrade Xray.
  -h, --help                 Show help.

Example:
  bash install-physics-vless-single.sh --port 443 --server 1.2.3.4

Direct one-line:
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-physics-vless-single.sh)" -- --port 443
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        PORT="${2:-}"
        shift 2
        ;;
      --server)
        SERVER_ADDR="${2:-}"
        shift 2
        ;;
      --sni)
        SNI="${2:-}"
        shift 2
        ;;
      --dest)
        DEST="${2:-}"
        shift 2
        ;;
      --keep-old)
        PURGE_OLD=0
        shift
        ;;
      --no-bbr)
        ENABLE_BBR=0
        shift
        ;;
      --no-firewall)
        OPEN_FIREWALL=0
        shift
        ;;
      --no-install)
        INSTALL_XRAY=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_root

  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Invalid port: $PORT"
  (( PORT >= 1 && PORT <= 65535 )) || die "Port out of range: $PORT"
  [[ -n "$SNI" ]] || die "SNI cannot be empty."
  [[ -n "$DEST" ]] || die "Dest cannot be empty."

  local installer
  installer="/tmp/install-vless-reality.$$.sh"

  command -v curl >/dev/null 2>&1 || die "curl is required."
  curl -fsSL "$RAW_URL" -o "$installer"
  chmod 700 "$installer"

  local args=(
    --port "$PORT"
    --sni "$SNI"
    --dest "$DEST"
  )

  [[ -n "$SERVER_ADDR" ]] && args+=(--server "$SERVER_ADDR")
  [[ "$PURGE_OLD" -eq 1 ]] && args+=(--purge-old)
  [[ "$ENABLE_BBR" -eq 0 ]] && args+=(--no-bbr)
  [[ "$OPEN_FIREWALL" -eq 0 ]] && args+=(--no-firewall)
  [[ "$INSTALL_XRAY" -eq 0 ]] && args+=(--no-install)

  exec bash "$installer" "${args[@]}"
}

main "$@"
