#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/ericyiu9819/x420/main}"
PKG_BASE="${PKG_BASE:-$REPO_RAW_BASE/kernel-netopt/packages}"
KERNEL_VERSION="6.18.35-vps-bbr"
PKG_VERSION="6.18.35-1"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

case "$ARCH" in
  amd64|x86_64)
    DEB_ARCH="amd64"
    ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 2
    ;;
esac

IMAGE="linux-image-${KERNEL_VERSION}_${PKG_VERSION}_${DEB_ARCH}.deb"
HEADERS="linux-headers-${KERNEL_VERSION}_${PKG_VERSION}_${DEB_ARCH}.deb"
LIBC_DEV="linux-libc-dev_${PKG_VERSION}_${DEB_ARCH}.deb"
WORKDIR="${WORKDIR:-/root/x-kernel-install}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "please run as root" >&2
    exit 1
  fi
}

fetch() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "missing curl or wget" >&2
    exit 1
  fi
}

precheck() {
  echo "== system =="
  cat /etc/os-release 2>/dev/null || true
  uname -a
  echo "arch=$ARCH"

  if ! command -v dpkg >/dev/null 2>&1; then
    echo "this installer supports Debian/Ubuntu dpkg systems only" >&2
    exit 2
  fi

  echo "== boot space =="
  df -h /boot / || true

  echo "== secure boot =="
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state || true
    if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
      echo "Secure Boot appears enabled. Refusing to install unsigned custom kernel." >&2
      exit 3
    fi
  else
    echo "mokutil unavailable; assuming BIOS or non-Secure-Boot VPS"
  fi

  echo "== current boot kernels =="
  find /boot -maxdepth 1 -name 'vmlinuz-*' -print | sort || true
}

install_kernel() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  echo "== download =="
  fetch "$PKG_BASE/$IMAGE" "$IMAGE"
  fetch "$PKG_BASE/$HEADERS" "$HEADERS"
  fetch "$PKG_BASE/$LIBC_DEV" "$LIBC_DEV"
  fetch "$PKG_BASE/SHA256SUMS" "SHA256SUMS"

  echo "== verify sha256 =="
  sha256sum -c SHA256SUMS

  echo "== install packages =="
  dpkg -i "$IMAGE" "$HEADERS" "$LIBC_DEV"

  echo "== update grub =="
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    echo "warning: no grub update command found" >&2
  fi

  echo "== keep old kernels visible =="
  find /boot -maxdepth 1 -name 'vmlinuz-*' -print | sort || true

  echo "== write x sysctl profile =="
  cat >/etc/sysctl.d/99-vps-bbr.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
SYSCTL
  sysctl --system >/dev/null || true
}

post_message() {
  cat <<MSG

Installed kernel packages for: $KERNEL_VERSION

Do not assume success until reboot validation.
Recommended test reboot path:

  1. Confirm provider console/GRUB rollback access is available.
  2. Reboot manually.
  3. Verify:

     uname -r
     sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing
     grep -w bbr /proc/sys/net/ipv4/tcp_available_congestion_control
     tc qdisc show dev eth0
     ip addr
     mount | grep ' / '

Rollback:

  1. Select old kernel in GRUB advanced options.
  2. Remove /etc/sysctl.d/99-vps-bbr.conf and run sysctl --system.
  3. apt remove linux-image-${KERNEL_VERSION} linux-headers-${KERNEL_VERSION}
  4. update-grub

MSG
}

need_root
precheck
install_kernel
post_message
