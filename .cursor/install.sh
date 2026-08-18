#!/usr/bin/env bash
# Idempotent development environment setup for the x420 VLESS installer scripts.
# Installs the tooling needed to lint, format, and end-to-end test the bash
# installers (shellcheck, shfmt) plus the xray-core runtime and helpers used by
# the scripts' self-test paths (xray, iproute2/ss, curl, openssl, jq, unzip).
set -euo pipefail

SHFMT_VERSION="v3.10.0"
XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

log() { printf '[install] %s\n' "$*"; }

install_apt_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "apt-get not found; skipping system package install"
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    shellcheck iproute2 curl ca-certificates openssl jq unzip
}

install_shfmt() {
  if command -v shfmt >/dev/null 2>&1 && [[ "$(shfmt --version 2>/dev/null)" == "$SHFMT_VERSION" ]]; then
    log "shfmt $SHFMT_VERSION already installed"
    return
  fi
  log "Installing shfmt $SHFMT_VERSION"
  local url="https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_amd64"
  sudo curl -fsSL "$url" -o /usr/local/bin/shfmt
  sudo chmod +x /usr/local/bin/shfmt
}

install_xray() {
  if command -v xray >/dev/null 2>&1 || [[ -x /usr/local/bin/xray ]]; then
    log "xray already installed: $(/usr/local/bin/xray version 2>/dev/null | head -n1)"
    return
  fi
  log "Installing xray-core"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$XRAY_ZIP_URL" -o "$tmp/xray.zip"
  unzip -o "$tmp/xray.zip" -d "$tmp/xray" >/dev/null
  sudo install -m 755 "$tmp/xray/xray" /usr/local/bin/xray
  sudo mkdir -p /usr/local/share/xray
  if [[ -f "$tmp/xray/geoip.dat" ]]; then
    sudo install -m 644 "$tmp/xray/geoip.dat" "$tmp/xray/geosite.dat" /usr/local/share/xray/
  fi
  rm -rf "$tmp"
}

main() {
  install_apt_packages
  install_shfmt
  install_xray

  log "Versions:"
  shellcheck --version | awk '/version:/ {print "  shellcheck " $2}'
  echo "  shfmt $(shfmt --version)"
  echo "  $(/usr/local/bin/xray version | head -n1)"
  log "Development environment ready"
}

main "$@"
