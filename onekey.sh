#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_BASE="${X420_RAW_BASE:-https://raw.githubusercontent.com/ericyiu9819/x420/main}"
INSTALL_URL="${REPO_RAW_BASE}/install.sh"

PORT="${X420_PORT:-443}"
SNI="${X420_SNI:-www.apple.com}"
REMARK="${X420_REMARK:-C-VLESS-TLS}"
HOST="${X420_HOST:-}"
UUID="${X420_UUID:-}"
WORKERS="${X420_WORKERS:-}"
BUFFER_SIZE="${X420_BUFFER_SIZE:-}"
PIPE_SIZE="${X420_PIPE_SIZE:-}"

log() {
  printf '[x420-onekey] %s\n' "$*" >&2
}

die() {
  printf '[x420-onekey] ERROR: %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root. Example: sudo bash <(curl -fsSL ${REPO_RAW_BASE}/onekey.sh)"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_bootstrap_tools() {
  have_cmd curl && have_cmd bash && return 0

  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates bash coreutils
  elif have_cmd dnf; then
    dnf install -y curl ca-certificates bash coreutils
  elif have_cmd yum; then
    yum install -y curl ca-certificates bash coreutils
  elif have_cmd zypper; then
    zypper --non-interactive install curl ca-certificates bash coreutils
  else
    die "curl is missing and no supported package manager was found."
  fi
}

usage() {
  cat <<EOF
Usage:
  bash <(curl -fsSL ${REPO_RAW_BASE}/onekey.sh) [installer options]

Default install:
  port:   ${PORT}
  tls:    enabled
  sni:    ${SNI}
  remark: ${REMARK}

Useful environment overrides:
  X420_HOST=1.2.3.4
  X420_PORT=443
  X420_SNI=www.apple.com
  X420_REMARK=C-VLESS-TLS
  X420_UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  X420_WORKERS=2

Examples:
  bash <(curl -fsSL ${REPO_RAW_BASE}/onekey.sh)
  X420_HOST=1.2.3.4 bash <(curl -fsSL ${REPO_RAW_BASE}/onekey.sh)
  bash <(curl -fsSL ${REPO_RAW_BASE}/onekey.sh) --host 1.2.3.4 --sni www.apple.com
  bash <(curl -fsSL ${REPO_RAW_BASE}/onekey.sh) status
  bash <(curl -fsSL ${REPO_RAW_BASE}/onekey.sh) uninstall
EOF
}

download() {
  local url="$1"
  local output="$2"
  curl --retry 6 --retry-delay 2 --retry-all-errors -fsSL "${url}" -o "${output}"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  need_root
  install_bootstrap_tools

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  log "downloading installer..."
  download "${INSTALL_URL}" "${tmp_dir}/install.sh"
  chmod 700 "${tmp_dir}/install.sh"
  bash -n "${tmp_dir}/install.sh"

  case "${1:-install}" in
    status|validate|print-client|restart|uninstall)
      exec bash "${tmp_dir}/install.sh" "$@"
      ;;
  esac

  local args=(install --port "${PORT}" --tls --sni "${SNI}" --remark "${REMARK}")
  [[ -n "${HOST}" ]] && args+=(--host "${HOST}")
  [[ -n "${UUID}" ]] && args+=(--uuid "${UUID}")
  [[ -n "${WORKERS}" ]] && args+=(--workers "${WORKERS}")
  [[ -n "${BUFFER_SIZE}" ]] && args+=(--buffer "${BUFFER_SIZE}")
  [[ -n "${PIPE_SIZE}" ]] && args+=(--pipe-size "${PIPE_SIZE}")

  log "starting C-VLESS/TLS install..."
  exec bash "${tmp_dir}/install.sh" "${args[@]}" "$@"
}

main "$@"
