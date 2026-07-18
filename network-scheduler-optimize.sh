#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="$(basename "$0")"

SYSCTL_FILE="/etc/sysctl.d/99-z-network-scheduler-optimization.conf"
APPLY_SCRIPT="/usr/local/sbin/apply-network-scheduler-qdisc.sh"
SYSTEMD_UNIT="/etc/systemd/system/network-scheduler-qdisc.service"

COMMAND="apply"
QDISC="fq"
NOTSENT_LOWAT="131072"
ENABLE_BBR="1"
SOMAXCONN="65535"
SYN_BACKLOG="65535"
NETDEV_BACKLOG="250000"
RMEM_MAX="134217728"
WMEM_MAX="134217728"
TCP_RMEM="4096 87380 67108864"
TCP_WMEM="4096 65536 67108864"
LOCAL_PORT_RANGE="10000 65000"
FIN_TIMEOUT="15"
TW_REUSE="1"
KEEPALIVE_TIME="120"
KEEPALIVE_INTVL="20"
KEEPALIVE_PROBES="3"
FASTOPEN="3"

usage() {
  cat <<USAGE
Usage:
  sudo ./${PROGRAM_NAME} [apply|status|remove] [options]

Commands:
  apply                 Apply network scheduling optimization and enable boot persistence. Default.
  status                Show current qdisc, sysctl, and service status.
  remove                Remove this script's persistence files. Live qdisc is left unchanged until reboot or manual change.

Options:
  --qdisc NAME          Root qdisc to apply to default-route interfaces. Default: ${QDISC}
  --notsent-lowat BYTES TCP unsent-data low water mark. Default: ${NOTSENT_LOWAT}
  --no-bbr              Do not set net.ipv4.tcp_congestion_control=bbr
  -h, --help            Show this help

Purpose:
  This script optimizes server-side network flow movement. It does not install Xray, change VLESS,
  change REALITY SNI, or edit proxy credentials.

Recommended for VLESS Reality TCP:
  fq qdisc + BBR + backlog/buffer tuning + MTU probing + faster idle recovery + tcp_notsent_lowat=131072

USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "[+] $*"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "This command must be run as root. Use sudo."
  fi
}

parse_args() {
  if [[ "$#" -gt 0 ]]; then
    case "$1" in
      apply|status|remove)
        COMMAND="$1"
        shift
        ;;
    esac
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --qdisc)
        QDISC="${2:-}"
        shift 2
        ;;
      --notsent-lowat)
        NOTSENT_LOWAT="${2:-}"
        shift 2
        ;;
      --no-bbr)
        ENABLE_BBR="0"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option or command: $1"
        ;;
    esac
  done
}

validate_args() {
  [[ "${COMMAND}" =~ ^(apply|status|remove)$ ]] || fail "Invalid command: ${COMMAND}"
  [[ "${QDISC}" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "--qdisc must be a simple qdisc name"
  [[ "${NOTSENT_LOWAT}" =~ ^[0-9]+$ ]] || fail "--notsent-lowat must be a positive integer"
  (( NOTSENT_LOWAT >= 16384 && NOTSENT_LOWAT <= 16777216 )) || fail "--notsent-lowat should be between 16384 and 16777216"
}

require_linux_tools() {
  [[ "$(uname -s)" == "Linux" ]] || fail "Only Linux is supported."
  command -v ip >/dev/null 2>&1 || fail "ip command is required. Install iproute2."
  command -v tc >/dev/null 2>&1 || fail "tc command is required. Install iproute2."
  command -v sysctl >/dev/null 2>&1 || fail "sysctl command is required."
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required for persistence."
}

default_route_devs() {
  local devs

  devs="$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | sort -u)"
  if [[ -z "${devs}" ]]; then
    devs="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi

  [[ -n "${devs}" ]] || fail "Could not detect a default-route network interface"
  printf '%s\n' "${devs}"
}

ensure_kernel_support() {
  if command -v modprobe >/dev/null 2>&1; then
    modprobe "sch_${QDISC}" 2>/dev/null || true
    if [[ "${ENABLE_BBR}" == "1" ]]; then
      modprobe tcp_bbr 2>/dev/null || true
    fi
  fi

  local first_dev
  first_dev="$(default_route_devs | head -n1)"
  if ! tc qdisc replace dev "${first_dev}" root "${QDISC}" 2>/tmp/network-scheduler-qdisc-check.log; then
    cat /tmp/network-scheduler-qdisc-check.log >&2 || true
    fail "qdisc '${QDISC}' is not supported on interface ${first_dev}"
  fi

  if [[ "${ENABLE_BBR}" == "1" ]]; then
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
      fail "BBR is not available on this kernel. Re-run with --no-bbr or upgrade the kernel."
    fi
  fi
}

write_apply_script() {
  info "Writing ${APPLY_SCRIPT}"
  cat > "${APPLY_SCRIPT}" <<EOF
#!/bin/sh
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
QDISC="${QDISC}"
DEVS="\$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if (\$i=="dev") print \$(i+1)}' | sort -u)"
if [ -z "\${DEVS}" ]; then
  DEVS="\$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if (\$i=="dev") {print \$(i+1); exit}}')"
fi
[ -n "\${DEVS}" ]
for dev in \${DEVS}; do
  tc qdisc replace dev "\${dev}" root "\${QDISC}"
done
EOF
  chmod 0755 "${APPLY_SCRIPT}"
}

write_sysctl_file() {
  info "Writing ${SYSCTL_FILE}"
  cat > "${SYSCTL_FILE}" <<EOF
# Server-side network flow optimization.
# Focus: reduce queueing, speed up flow movement inside the kernel, and lower head-of-line impact.
# This file intentionally avoids proxy configuration and credential changes.

# 1. Egress scheduler: make active TCP flows share the NIC queue more fairly.
net.core.default_qdisc = ${QDISC}

# 2. Inbound accept queues: absorb short connection bursts without listener drops.
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}

# 3. TCP buffers: allow enough window for high-latency paths without forcing huge per-connection buffers.
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}
net.ipv4.tcp_moderate_rcvbuf = 1

# 4. Outbound connection capacity and cleanup.
net.ipv4.ip_local_port_range = ${LOCAL_PORT_RANGE}
net.ipv4.tcp_fin_timeout = ${FIN_TIMEOUT}
net.ipv4.tcp_tw_reuse = ${TW_REUSE}

# 5. Flow recovery: avoid stale idle connections and recover faster after idle periods.
net.ipv4.tcp_keepalive_time = ${KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl = ${KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${KEEPALIVE_PROBES}
net.ipv4.tcp_slow_start_after_idle = 0

# 6. Path adaptation: reduce blackhole/MTU stalls and allow Fast Open when both sides support it.
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = ${FASTOPEN}

# 7. Sender pacing: keep one TCP flow from filling too much unsent kernel buffer.
net.ipv4.tcp_notsent_lowat = ${NOTSENT_LOWAT}
EOF

  if [[ "${ENABLE_BBR}" == "1" ]]; then
    cat >> "${SYSCTL_FILE}" <<EOF
net.ipv4.tcp_congestion_control = bbr
EOF
  fi
}

write_systemd_unit() {
  info "Writing ${SYSTEMD_UNIT}"
  cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Apply network scheduler qdisc optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

apply_sysctl_values() {
  local line
  local key
  local value

  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" == *"="* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "${key}" | xargs)"
    value="$(printf '%s' "${value}" | xargs)"

    if ! sysctl -q -w "${key}=${value}"; then
      echo "WARN: could not apply ${key}; skipped" >&2
    fi
  done < "${SYSCTL_FILE}"
}

apply_optimization() {
  need_root
  require_linux_tools
  ensure_kernel_support
  write_apply_script
  write_sysctl_file
  write_systemd_unit

  info "Applying sysctl values"
  apply_sysctl_values

  info "Applying qdisc to default-route interfaces"
  "${APPLY_SCRIPT}"

  info "Enabling boot persistence"
  systemctl daemon-reload
  systemctl enable --now "$(basename "${SYSTEMD_UNIT}")"

  print_status
}

remove_optimization() {
  need_root
  require_linux_tools

  info "Disabling persistence service if present"
  systemctl disable --now "$(basename "${SYSTEMD_UNIT}")" 2>/dev/null || true

  info "Removing persistence files"
  rm -f "${SYSTEMD_UNIT}" "${APPLY_SCRIPT}" "${SYSCTL_FILE}"
  systemctl daemon-reload

  info "Reloading sysctl from remaining system files"
  sysctl --system >/dev/null 2>&1 || true

  cat <<EOF

Removed this script's persistence files.
Live qdisc may remain active until reboot or manual replacement.
Run:
  tc qdisc show
  sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_notsent_lowat net.ipv4.tcp_fastopen

EOF
}

print_status() {
  require_linux_tools

  local dev

  cat <<EOF

==================== NETWORK SCHEDULER STATUS ====================
Default-route interfaces:
$(default_route_devs)

Qdisc:
EOF

  while IFS= read -r dev; do
    tc qdisc show dev "${dev}" || true
  done < <(default_route_devs)

  cat <<EOF

Sysctl:
$(sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.ip_local_port_range net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.ipv4.tcp_notsent_lowat 2>/dev/null || true)

Service:
$(systemctl is-enabled "$(basename "${SYSTEMD_UNIT}")" 2>/dev/null || true)
$(systemctl is-active "$(basename "${SYSTEMD_UNIT}")" 2>/dev/null || true)
==================================================================

EOF
}

main() {
  parse_args "$@"
  validate_args

  case "${COMMAND}" in
    apply)
      apply_optimization
      ;;
    status)
      print_status
      ;;
    remove)
      remove_optimization
      ;;
  esac
}

main "$@"
