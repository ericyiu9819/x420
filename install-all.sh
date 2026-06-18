#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/ericyiu9819/x420/main}"
INSTALL_X420="${INSTALL_X420:-1}"
INSTALL_X_NET="${INSTALL_X_NET:-1}"
INSTALL_KERNEL="${INSTALL_KERNEL:-0}"
X_LIMIT_URL="${X_LIMIT_URL:-https://nbg1-speed.hetzner.com/100MB.bin}"
X_LIMIT_RTT_HOST="${X_LIMIT_RTT_HOST:-}"

usage() {
  cat <<'EOF'
x420 全功能一键安装脚本

默认安装：
  1. x420 TCP REALITY 代理
  2. x420 物理极限网络算法与最小 BBR/fq 参数

默认不安装自定义内核，因为内核安装涉及 GRUB 和重启风险。
默认跳过 UFW 防火墙配置，避免精简内核缺少 iptables/nft 兼容路径时中断安装。

用法：
  bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)

安装代理 + x 网络算法 + 自定义内核：
  INSTALL_KERNEL=1 bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)

只安装 x420 物理极限网络算法，不装代理：
  INSTALL_X420=0 bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)

常用变量：
  INSTALL_X420=1
  INSTALL_X_NET=1
  INSTALL_KERNEL=0
  X_LIMIT_URL=https://nbg1-speed.hetzner.com/100MB.bin
  X_LIMIT_RTT_HOST=
  SERVER_PORT=443
  REALITY_SERVER_NAME=www.microsoft.com
  REALITY_TARGET_DOMAIN=www.microsoft.com
  NODE_LABEL=x420
  SKIP_FIREWALL=1
  SKIP_TUNE=1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: please run as root" >&2
    exit 1
  fi
}

fetch() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    echo "missing curl or wget" >&2
    exit 1
  fi
}

install_base_deps() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl ca-certificates python3 iproute2 kmod
  else
    echo "error: this installer currently supports Debian/Ubuntu apt systems only" >&2
    exit 2
  fi
}

install_x420() {
  echo "== install x420 TCP REALITY =="
  local script="/tmp/x420-install.sh"
  fetch "$REPO_RAW_BASE/install.sh" "$script"
  chmod +x "$script"
  SKIP_TUNE="${SKIP_TUNE:-1}" SKIP_FIREWALL="${SKIP_FIREWALL:-1}" bash "$script"
}

install_x_net_tool() {
  echo "== install x420 physical-limit network controller =="
  local tool="/usr/local/sbin/x420-limit"
  fetch "$REPO_RAW_BASE/tools/physical_limit_controller.py" "$tool"
  chmod +x "$tool"

  rm -f /usr/local/sbin/x /usr/local/sbin/x-net-probe /usr/local/sbin/x420-net-control /usr/local/sbin/x420-aggressive /usr/local/sbin/x420-bbrplus

  cat >/etc/sysctl.d/99-x420-physical-limit.conf <<'SYSCTL'
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

install_custom_kernel() {
  echo "== install x custom kernel =="
  echo "warning: custom kernel installation modifies /boot and GRUB. It will not reboot automatically."
  local script="/tmp/install-x-kernel.sh"
  fetch "$REPO_RAW_BASE/install-x-kernel.sh" "$script"
  chmod +x "$script"
  bash "$script"
}

summary() {
  echo
  echo "== x420 all-in-one install summary =="
  echo "kernel: $(uname -r)"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^xray.service'; then
    echo "xray: $(systemctl is-active xray || true)"
  fi
  echo
  echo "x420 limit tool: /usr/local/sbin/x420-limit"
  echo "x420 sysctl: /etc/sysctl.d/99-x420-physical-limit.conf"
  echo "discover example:"
  echo "  x420-limit discover --url \"${X_LIMIT_URL:-https://nbg1-speed.hetzner.com/100MB.bin}\" ${X_LIMIT_RTT_HOST:+--rtt-host \"$X_LIMIT_RTT_HOST\"}"
  echo
  if [[ "$INSTALL_KERNEL" != "1" ]]; then
    echo "Custom kernel was not installed. To install it explicitly:"
    echo "  INSTALL_KERNEL=1 bash <(curl -fsSL $REPO_RAW_BASE/install-all.sh)"
  else
    echo "Custom kernel packages were installed. Reboot manually only after confirming GRUB rollback access."
  fi
}

need_root
install_base_deps

if [[ "$INSTALL_X420" == "1" ]]; then
  install_x420
fi

if [[ "$INSTALL_X_NET" == "1" ]]; then
  install_x_net_tool
fi

if [[ "$INSTALL_KERNEL" == "1" ]]; then
  install_custom_kernel
fi

summary
