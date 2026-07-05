#!/usr/bin/env bash
set -Eeuo pipefail

# First-principles VLESS single-VPS installer entrypoint.
#
# Core facts:
#   1. The shortest proxy path is one ingress hop, then direct outbound.
#   2. For daily TCP use, every extra tunnel layer adds latency, state and failure surface.
#   3. Stable long connections need a long Xray idle window, TCP keepalive and fast dead-link detection.
#
# Final topology:
#   client -> VLESS/TCP/REALITY/Vision -> single VPS -> target
#
# This script intentionally avoids CDN, WebSocket, gRPC and multi-hop modes.

PORT="${XRAY_PORT:-443}"
SNI="${REALITY_SNI:-www.cloudflare.com}"
DEST="${REALITY_DEST:-www.cloudflare.com:443}"
SERVER_ADDR="${SERVER_ADDR:-}"
PURGE_OLD=1
ENABLE_BBR=1
OPEN_FIREWALL=1
INSTALL_XRAY=1
BASE_INSTALLER_URL="${BASE_INSTALLER_URL:-https://raw.githubusercontent.com/ericyiu9819/x420/main/install-vless-reality.sh}"

usage() {
  cat <<'EOF'
Usage:
  bash install-first-principles-vless-single.sh [options]

Default scheme:
  VLESS + TCP + REALITY + Vision
  one VPS only, no CDN, no WS, no gRPC, no relay chain
  BBR/fq TCP tuning, TCP keepalive, long idle window

Options:
  --port <port>              Listen TCP port. Default: 443
  --server <domain_or_ip>    Address shown in the client link. Auto-detected if omitted.
  --sni <domain>             REALITY serverName. Default: www.cloudflare.com
  --dest <host:port>         REALITY dest. Default: www.cloudflare.com:443
  --keep-old                 Keep old Xray config/drop-ins instead of purging them.
  --no-bbr                   Do not apply kernel TCP/BBR tuning.
  --no-firewall              Do not open firewall port automatically.
  --no-install               Do not install/upgrade Xray; only rewrite config.
  -h, --help                 Show help.

One-line install:
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-first-principles-vless-single.sh)" -- --port 443

Local install:
  bash install-first-principles-vless-single.sh --port 443 --server 1.2.3.4
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[INFO] %s\n' "$*" >&2
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

validate_inputs() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Invalid port: $PORT"
  (( PORT >= 1 && PORT <= 65535 )) || die "Port out of range: $PORT"
  [[ -n "$SNI" ]] || die "SNI cannot be empty."
  [[ -n "$DEST" ]] || die "Dest cannot be empty."
}

download_base_installer() {
  local installer="$1"

  command -v curl >/dev/null 2>&1 || die "curl is required."
  log "Downloading base installer."
  curl -fsSL "$BASE_INSTALLER_URL" -o "$installer"
  chmod 700 "$installer"
}

resolve_base_installer() {
  local local_installer
  local tmp_installer

  local_installer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-vless-reality.sh"
  if [[ -f "$local_installer" ]]; then
    printf '%s\n' "$local_installer"
    return
  fi

  tmp_installer="/tmp/install-vless-reality.$$.sh"
  download_base_installer "$tmp_installer"
  printf '%s\n' "$tmp_installer"
}

main() {
  parse_args "$@"
  validate_inputs
  require_root

  local installer
  installer="$(resolve_base_installer)"

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
