#!/usr/bin/env bash
set -euo pipefail

# Single VPS shortest-path Xray setup:
# client -> VPS:PORT -> internet
#
# One-line install:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-vless-reality.sh)"
#
# Useful overrides:
#   SERVER_ADDR=1.2.3.4 bash install-vless-reality.sh
#   SERVER_NAME=www.tesla.com TARGET=www.tesla.com:443 bash install-vless-reality.sh
#   TUNING_PROFILE=aggressive bash install-vless-reality.sh
#   ENABLE_NET_TUNING=0 bash install-vless-reality.sh

PORT="${PORT:-443}"
SERVER_NAME="${SERVER_NAME:-www.tesla.com}"
TARGET="${TARGET:-${SERVER_NAME}:443}"
EMAIL="${EMAIL:-main@vless-reality}"
ENABLE_NET_TUNING="${ENABLE_NET_TUNING:-1}"
TUNING_PROFILE="${TUNING_PROFILE:-auto}"
USER_TCP_BUFFER_MAX="${TCP_BUFFER_MAX:-}"
USER_XRAY_NOFILE_LIMIT="${XRAY_NOFILE_LIMIT:-}"

CONFIG_PATH="/usr/local/etc/xray/config.json"
CLIENT_INFO_PATH="/root/vless-reality-client.txt"
TUNING_REPORT_PATH="/root/vless-reality-tuning-report.txt"
SYSCTL_TUNE_PATH="/etc/sysctl.d/99-xray-vless-reality-net.conf"
MODULES_LOAD_PATH="/etc/modules-load.d/99-xray-vless-reality.conf"
XRAY_SERVICE_OVERRIDE_DIR="/etc/systemd/system/xray.service.d"
XRAY_SERVICE_OVERRIDE_PATH="${XRAY_SERVICE_OVERRIDE_DIR}/10-limits.conf"

TUNING_SELECTED_PROFILE="unknown"
TUNING_MEM_MB="0"
TUNING_CPU_CORES="1"
TUNING_KERNEL="unknown"
TUNING_DEFAULT_DEV="unknown"
TUNING_DEV_MTU="unknown"
TUNING_DEV_SPEED_MBPS="unknown"
TUNING_TARGET_TIMING="not measured"
TUNING_AVAILABLE_CC="unknown"
TUNING_TCP_BUFFER_MAX="67108864"
TUNING_SOMAXCONN="4096"
TUNING_SYN_BACKLOG="8192"
TUNING_NETDEV_BACKLOG="16384"
TUNING_NOFILE_LIMIT="1048576"
TUNING_APPLIED_BBR="no"
TUNING_APPLIED_QDISC="no"
TUNING_NOTES=""
XRAY_NOFILE_LIMIT="1048576"

log() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

validate_inputs() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root."
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    die "This script requires a systemd-based Linux VPS."
  fi

  if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    die "PORT must be an integer between 1 and 65535."
  fi

  if [[ "${ENABLE_NET_TUNING}" != "0" && "${ENABLE_NET_TUNING}" != "1" ]]; then
    die "ENABLE_NET_TUNING must be 0 or 1."
  fi

  case "${TUNING_PROFILE}" in
    auto|conservative|standard|aggressive) ;;
    *) die "TUNING_PROFILE must be auto, conservative, standard, or aggressive." ;;
  esac

  if [[ -n "${USER_TCP_BUFFER_MAX}" ]] && { ! [[ "${USER_TCP_BUFFER_MAX}" =~ ^[0-9]+$ ]] || (( USER_TCP_BUFFER_MAX < 1 )); }; then
    die "TCP_BUFFER_MAX must be a positive integer."
  fi

  if [[ -n "${USER_XRAY_NOFILE_LIMIT}" ]] && { ! [[ "${USER_XRAY_NOFILE_LIMIT}" =~ ^[0-9]+$ ]] || (( USER_XRAY_NOFILE_LIMIT < 1 )); }; then
    die "XRAY_NOFILE_LIMIT must be a positive integer."
  fi

  if [[ -z "${SERVER_NAME}" || -z "${TARGET}" ]]; then
    die "SERVER_NAME and TARGET cannot be empty."
  fi
}

install_base_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl ca-certificates openssl iproute2 kmod unzip procps ethtool
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y \
      curl ca-certificates openssl iproute kmod unzip procps-ng ethtool
  elif command -v yum >/dev/null 2>&1; then
    yum install -y \
      curl ca-certificates openssl iproute kmod unzip procps-ng ethtool
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install \
      curl ca-certificates openssl iproute2 kmod unzip procps ethtool
  else
    die "Unsupported package manager. Install curl, ca-certificates, openssl, iproute, kmod, unzip, procps, and ethtool first."
  fi
}

install_xray() {
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

detect_xray_bin() {
  if command -v xray >/dev/null 2>&1; then
    command -v xray
  elif [[ -x /usr/local/bin/xray ]]; then
    echo "/usr/local/bin/xray"
  else
    die "xray binary not found after installation."
  fi
}

detect_server_addr() {
  if [[ -n "${SERVER_ADDR:-}" ]]; then
    echo "${SERVER_ADDR}"
    return
  fi

  local addr
  addr="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${addr}" ]]; then
    addr="$(curl -4 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -z "${addr}" ]]; then
    addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -z "${addr}" ]]; then
    die "Could not detect VPS public address. Re-run with SERVER_ADDR=your.domain.or.ip"
  fi

  echo "${addr}"
}

detect_mem_mb() {
  awk '/MemTotal/ {printf "%.0f\n", $2 / 1024; found=1} END {if (!found) print 0}' /proc/meminfo 2>/dev/null || echo 0
}

detect_cpu_cores() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
  fi
}

detect_default_dev() {
  local dev
  dev="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)"
  if [[ -z "${dev}" ]]; then
    dev="$(ip -o -6 route show default 2>/dev/null | awk '{print $5; exit}' || true)"
  fi
  echo "${dev:-unknown}"
}

detect_iface_mtu() {
  local dev="$1"
  if [[ -z "${dev}" || "${dev}" == "unknown" ]]; then
    echo "unknown"
    return
  fi

  local mtu
  mtu="$(ip -o link show dev "${dev}" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="mtu") {print $(i+1); exit}}' || true)"
  echo "${mtu:-unknown}"
}

detect_iface_speed_mbps() {
  local dev="$1"
  if [[ -z "${dev}" || "${dev}" == "unknown" ]] || ! command -v ethtool >/dev/null 2>&1; then
    echo "unknown"
    return
  fi

  local speed
  speed="$(ethtool "${dev}" 2>/dev/null | awk -F': *' '/Speed:/ {print $2; exit}' | tr -d ' ' || true)"
  case "${speed}" in
    *Mb/s) echo "${speed%Mb/s}" ;;
    *Gb/s)
      local gb
      gb="${speed%Gb/s}"
      awk -v gb="${gb}" 'BEGIN {printf "%.0f\n", gb * 1000}'
      ;;
    *) echo "unknown" ;;
  esac
}

measure_target_tls() {
  local timing
  timing="$(curl -4 -o /dev/null -sS \
    --connect-timeout 5 \
    --max-time 10 \
    -w 'connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s' \
    "https://${SERVER_NAME}/" 2>/dev/null || true)"

  if [[ -n "${timing}" ]]; then
    echo "${timing}"
  else
    echo "unavailable"
  fi
}

select_auto_profile() {
  local mem_mb="$1"
  local cpu_cores="$2"
  local speed_mbps="$3"

  if (( mem_mb > 0 && mem_mb < 768 )); then
    echo "conservative"
    return
  fi

  if [[ "${speed_mbps}" =~ ^[0-9]+$ ]] && (( speed_mbps >= 1000 && mem_mb >= 4096 && cpu_cores >= 2 )); then
    echo "aggressive"
    return
  fi

  echo "standard"
}

append_tuning_note() {
  local note="$1"
  if [[ -z "${TUNING_NOTES}" ]]; then
    TUNING_NOTES="${note}"
  else
    TUNING_NOTES="${TUNING_NOTES}; ${note}"
  fi
}

build_tuning_plan() {
  TUNING_MEM_MB="$(detect_mem_mb)"
  TUNING_CPU_CORES="$(detect_cpu_cores)"
  TUNING_KERNEL="$(uname -r 2>/dev/null || echo unknown)"
  TUNING_DEFAULT_DEV="$(detect_default_dev)"
  TUNING_DEV_MTU="$(detect_iface_mtu "${TUNING_DEFAULT_DEV}")"
  TUNING_DEV_SPEED_MBPS="$(detect_iface_speed_mbps "${TUNING_DEFAULT_DEV}")"
  TUNING_TARGET_TIMING="$(measure_target_tls)"
  TUNING_AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo unknown)"

  if [[ "${TUNING_PROFILE}" == "auto" ]]; then
    TUNING_SELECTED_PROFILE="$(select_auto_profile "${TUNING_MEM_MB}" "${TUNING_CPU_CORES}" "${TUNING_DEV_SPEED_MBPS}")"
  else
    TUNING_SELECTED_PROFILE="${TUNING_PROFILE}"
  fi

  local default_buffer default_nofile
  case "${TUNING_SELECTED_PROFILE}" in
    conservative)
      default_buffer="33554432"
      TUNING_SOMAXCONN="2048"
      TUNING_SYN_BACKLOG="4096"
      TUNING_NETDEV_BACKLOG="5000"
      default_nofile="262144"
      ;;
    standard)
      default_buffer="67108864"
      TUNING_SOMAXCONN="4096"
      TUNING_SYN_BACKLOG="8192"
      TUNING_NETDEV_BACKLOG="16384"
      default_nofile="1048576"
      ;;
    aggressive)
      default_buffer="134217728"
      TUNING_SOMAXCONN="8192"
      TUNING_SYN_BACKLOG="16384"
      TUNING_NETDEV_BACKLOG="32768"
      default_nofile="1048576"
      ;;
    *)
      die "Internal error: unsupported selected tuning profile."
      ;;
  esac

  TUNING_TCP_BUFFER_MAX="${USER_TCP_BUFFER_MAX:-${default_buffer}}"
  XRAY_NOFILE_LIMIT="${USER_XRAY_NOFILE_LIMIT:-${default_nofile}}"
  TUNING_NOFILE_LIMIT="${XRAY_NOFILE_LIMIT}"

  if [[ "${TUNING_DEV_SPEED_MBPS}" == "unknown" ]]; then
    append_tuning_note "interface speed unavailable from ethtool; profile selected from CPU and memory"
  fi
  if [[ "${TUNING_TARGET_TIMING}" == "unavailable" ]]; then
    append_tuning_note "target TLS timing unavailable; this does not block REALITY setup"
  fi
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${PORT}/tcp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
  fi
}

check_port_available_for_xray() {
  if ! command -v ss >/dev/null 2>&1; then
    return
  fi

  local listeners
  listeners="$(ss -lntp 2>/dev/null | awk -v port=":${PORT}" '$4 ~ port "$" {print}' || true)"
  if [[ -n "${listeners}" ]] && ! grep -qi 'xray' <<<"${listeners}"; then
    printf '%s\n' "${listeners}" >&2
    die "Port ${PORT}/tcp is already in use by another service."
  fi
}

sysctl_path_for_key() {
  local key="$1"
  printf '/proc/sys/%s\n' "${key//./\/}"
}

set_supported_sysctl() {
  local output_file="$1"
  local key="$2"
  local value="$3"
  local path
  path="$(sysctl_path_for_key "${key}")"

  if [[ ! -e "${path}" ]]; then
    warn "Skipping unsupported sysctl: ${key}"
    return
  fi

  if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
    printf '%s = %s\n' "${key}" "${value}" >>"${output_file}"
  else
    warn "Skipping sysctl rejected by kernel: ${key}=${value}"
  fi
}

apply_fq_to_default_interfaces() {
  if ! command -v ip >/dev/null 2>&1 || ! command -v tc >/dev/null 2>&1; then
    return
  fi

  local applied="no" tmp_state
  tmp_state="$(mktemp)"
  ip -o route show default 2>/dev/null | awk '{print $5}' | sort -u | while read -r dev; do
    [[ -n "${dev}" ]] || continue
    if tc qdisc replace dev "${dev}" root fq 2>/dev/null; then
      log "Applied fq qdisc to interface: ${dev}"
      applied="yes"
    else
      warn "Could not apply fq qdisc to interface: ${dev}"
    fi
    printf '%s\n' "${applied}" >"${tmp_state}"
  done

  if [[ -s "${tmp_state}" ]]; then
    TUNING_APPLIED_QDISC="$(cat "${tmp_state}" 2>/dev/null || echo no)"
  fi
  rm -f "${tmp_state}"
}

configure_network_stack() {
  if [[ "${ENABLE_NET_TUNING}" != "1" ]]; then
    log "Network stack tuning skipped. Set ENABLE_NET_TUNING=1 to enable it."
    return
  fi

  log "Applying ${TUNING_SELECTED_PROFILE} network stack tuning..."

  local modules_to_load=()
  if modprobe tcp_bbr 2>/dev/null; then
    modules_to_load+=("tcp_bbr")
  fi
  if modprobe sch_fq 2>/dev/null; then
    modules_to_load+=("sch_fq")
  fi
  if (( ${#modules_to_load[@]} > 0 )); then
    mkdir -p "$(dirname "${MODULES_LOAD_PATH}")"
    printf '%s\n' "${modules_to_load[@]}" >"${MODULES_LOAD_PATH}"
  fi

  TUNING_AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo unknown)"

  local tmp_file
  tmp_file="$(mktemp)"
  {
    echo "# Generated by install-vless-reality.sh"
    echo "# Profile: ${TUNING_SELECTED_PROFILE}"
    echo "# Goal: improve pacing, congestion behavior, and connection resilience."
  } >"${tmp_file}"

  set_supported_sysctl "${tmp_file}" "net.core.default_qdisc" "fq"

  if printf '%s\n' "${TUNING_AVAILABLE_CC}" | grep -qw "bbr"; then
    set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_congestion_control" "bbr"
    TUNING_APPLIED_BBR="yes"
  else
    warn "BBR is not available on this kernel. Keeping current congestion control."
    append_tuning_note "BBR unavailable on this kernel"
  fi

  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_slow_start_after_idle" "0"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_mtu_probing" "1"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_syncookies" "1"

  set_supported_sysctl "${tmp_file}" "net.core.somaxconn" "${TUNING_SOMAXCONN}"
  set_supported_sysctl "${tmp_file}" "net.core.netdev_max_backlog" "${TUNING_NETDEV_BACKLOG}"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_max_syn_backlog" "${TUNING_SYN_BACKLOG}"
  set_supported_sysctl "${tmp_file}" "net.ipv4.ip_local_port_range" "1024 65535"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_tw_reuse" "1"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_fin_timeout" "15"

  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_keepalive_time" "600"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_keepalive_intvl" "30"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_keepalive_probes" "5"

  set_supported_sysctl "${tmp_file}" "net.core.rmem_max" "${TUNING_TCP_BUFFER_MAX}"
  set_supported_sysctl "${tmp_file}" "net.core.wmem_max" "${TUNING_TCP_BUFFER_MAX}"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_rmem" "4096 87380 ${TUNING_TCP_BUFFER_MAX}"
  set_supported_sysctl "${tmp_file}" "net.ipv4.tcp_wmem" "4096 65536 ${TUNING_TCP_BUFFER_MAX}"

  install -m 0644 "${tmp_file}" "${SYSCTL_TUNE_PATH}"
  rm -f "${tmp_file}"

  apply_fq_to_default_interfaces
}

configure_xray_service() {
  if ! id -u xray >/dev/null 2>&1; then
    useradd --system --home /nonexistent --no-create-home --shell /usr/sbin/nologin xray 2>/dev/null \
      || useradd -r -M -s /sbin/nologin xray
  fi

  chown -R xray:xray "$(dirname "${CONFIG_PATH}")" /var/log/xray /usr/local/share/xray 2>/dev/null || true
  chmod 750 "$(dirname "${CONFIG_PATH}")" 2>/dev/null || true
  chmod 640 "${CONFIG_PATH}" 2>/dev/null || true

  mkdir -p "${XRAY_SERVICE_OVERRIDE_DIR}"
  cat >"${XRAY_SERVICE_OVERRIDE_PATH}" <<EOF
[Service]
User=xray
Group=xray
LimitNOFILE=${XRAY_NOFILE_LIMIT}
EOF
  systemctl daemon-reload
}

test_xray_config() {
  local xray_bin="$1"

  "${xray_bin}" run -test -config "${CONFIG_PATH}"
  if command -v runuser >/dev/null 2>&1 && id -u xray >/dev/null 2>&1; then
    runuser -u xray -- "${xray_bin}" run -test -config "${CONFIG_PATH}" >/dev/null
  fi
}

restart_and_verify_xray() {
  systemctl enable xray >/dev/null
  systemctl restart xray
  sleep 1

  if ! systemctl is-active --quiet xray; then
    warn "Xray failed to start. Recent service log:"
    journalctl -u xray --no-pager -n 50 >&2 || true
    exit 1
  fi

  if command -v ss >/dev/null 2>&1 && ! ss -lnt | awk '{print $4}' | grep -Eq "(:|\\])${PORT}$"; then
    warn "Xray is active, but port ${PORT}/tcp is not listening."
    journalctl -u xray --no-pager -n 50 >&2 || true
    exit 1
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

make_vless_uri() {
  local uuid="$1"
  local host="$2"
  local public_key="$3"
  local short_id="$4"
  local name="vless-reality-vision"

  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none&spx=%%2F#%s\n' \
    "${uuid}" "${host}" "${PORT}" "${SERVER_NAME}" "${public_key}" "${short_id}" "${name}"
}

write_tuning_report() {
  local active_cc active_qdisc active_nofile active_user active_rmem active_wmem active_somax active_syn qdisc_detail
  active_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  active_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  active_nofile="$(systemctl show xray -p LimitNOFILE --value 2>/dev/null || echo unknown)"
  active_user="$(systemctl show xray -p User --value 2>/dev/null || echo unknown)"
  active_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
  active_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
  active_somax="$(sysctl -n net.core.somaxconn 2>/dev/null || echo unknown)"
  active_syn="$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo unknown)"
  qdisc_detail="$(tc qdisc show dev "${TUNING_DEFAULT_DEV}" 2>/dev/null | tr '\n' ';' || echo unknown)"

  cat >"${TUNING_REPORT_PATH}" <<EOF
VLESS REALITY adaptive tuning report

Requested profile: ${TUNING_PROFILE}
Selected profile: ${TUNING_SELECTED_PROFILE}
Network tuning enabled: ${ENABLE_NET_TUNING}

System facts:
Kernel: ${TUNING_KERNEL}
Memory MB: ${TUNING_MEM_MB}
CPU cores: ${TUNING_CPU_CORES}
Default interface: ${TUNING_DEFAULT_DEV}
Interface MTU: ${TUNING_DEV_MTU}
Interface speed Mbps: ${TUNING_DEV_SPEED_MBPS}
Target TLS timing: ${TUNING_TARGET_TIMING}
Available congestion controls: ${TUNING_AVAILABLE_CC}

Planned values:
TCP buffer max: ${TUNING_TCP_BUFFER_MAX}
somaxconn: ${TUNING_SOMAXCONN}
tcp_max_syn_backlog: ${TUNING_SYN_BACKLOG}
netdev_max_backlog: ${TUNING_NETDEV_BACKLOG}
Xray LimitNOFILE: ${TUNING_NOFILE_LIMIT}

Active values:
Congestion control: ${active_cc}
Default qdisc: ${active_qdisc}
Interface qdisc: ${qdisc_detail}
rmem_max: ${active_rmem}
wmem_max: ${active_wmem}
somaxconn: ${active_somax}
tcp_max_syn_backlog: ${active_syn}
Xray user: ${active_user}
Xray LimitNOFILE: ${active_nofile}

Files:
Sysctl profile: ${SYSCTL_TUNE_PATH}
Modules-load profile: ${MODULES_LOAD_PATH}
Xray override: ${XRAY_SERVICE_OVERRIDE_PATH}

Notes: ${TUNING_NOTES:-none}
EOF

  chmod 600 "${TUNING_REPORT_PATH}" 2>/dev/null || true
}

write_client_info() {
  local uri="$1"
  local server_addr="$2"
  local uuid="$3"
  local public_key="$4"
  local short_id="$5"
  local active_cc active_qdisc active_nofile active_user

  active_cc="$(sysctl -n net.ipv4.tcp_co™Щ\Э[Ы—ШЫЫќ›ЫЏ‹Щ]‹Ыќ[XЪИ[љЫ›ЭЫЉH‚€XЭ]™WЬY\ШПH‰
Ю\ШЭ[€™]ЫЬ™K™Y][ЬY\ШИЏ‹Щ]‹Ыќ[XЪИ[љЫ›ЭЫЉH‚€XЭ]™WЫ›Щљ[OH‰
Ю\Э[XЭЪЭИ^H\[Z]“С’SHK][YHЏ‹Щ]‹Ыќ[XЪИ[љЫ›ЭЫЉH‚€XЭ]™WЭ\Щ\ЏH‰
Ю\Э[XЭЪЭИ^H\\Щ\€K][YHЏ‹Щ]‹Ыќ[XЪИ[љЫ›ЭЫЉH‚‚€Ш]€‰РУQS•ТS‘“ЧФUH€SС‚•“TФИ‘PSUHљ\Ъ[Ы€ЫY[ќ\[Y]\њВ‚ђY™\ЬО€	ЬЩ\ќ™\—ШYџB”Ьќ€	ФФ•B•URQ€	Э]ZYB‘›ЭО€Л\њћ]љ\Ъ[Ы‚•[њЬЬќ€ЬЬ]В”ЩXЭ\љ]N€™X[]B”У’HИЩ\ќ™\“[YN€	ФСT•‘T—УђSQ_B”‘PSUHX›XИЩ^HИ\ЬЭЫЬ™€	ЬX›XЧЪЩ^_B”ЪЬќQ€	ЬЪЬќЪYB‘љ[™Щ\њљ[ќ€Ъ›ЫYB”ЬY\–€В‚’[\ЬќT’N‚‰Э\љ_B‚“™]ЫЬљИ[љ[™О‚‘[X›Y€	СSђP“WУ‘UХS’S‘ЯB”™\]Y\ЭY›Щљ[N€	ХS’S‘ЧФ“С’S_B”Щ[XЭY›Щљ[N€	ХS’S‘ЧФСSPХQФ“С’S_BђЫЫ™Щ\Э[Ы€ЫЫќ›Ы€	ШXЭ]™WШШЯB‘Y][Y\ШО€	ШXЭ]™WЬY\ШЯB•ФќY™™\€X^€	ХS’S‘ЧХФР•Q‘‘T—УPVB–^H\Щ\Ћ€	ШXЭ]™WЭ\Щ\џB–^H[Z]“С’SN€	ШXЭ]™WЫ›Щљ[_B•[љ[™И™\Ьќ€	ХS’S‘ЧФ‘TФ•ФUB‚”Щ\ќ™\€ЫЫ™љYО‚‰РУУ‘’QЧФUB‘SС‚‚€Ъ[ЩЊ‰РУQS•ТS‘“ЧФUH€Џ‹Щ]‹Ыќ[ќYBџB‚›XZ[Љ
HВ€[X\ЪИНВ€[Y]WЪ[њ]В‚€ЩИ’[њЭ[[™И\[™[ЪY\Л‹‹€‚€[њЭ[Ш\ЩWЩ\В‚€ЩИђќZ[[™ИY\]™H[љ[™И[‹‹‹€‚€ќZ[Э[љ[™ЧЬ[‚€ЩИ”Щ[XЭY[љ[™И›Щљ[N€	ХS’S‘ЧФСSPХQФ“С’S_H‚‚€ЩИ’[њЭ[[™ИЬ€\ЬY[™И^K‹‹€‚€[њЭ[Ю^B‚€ШШ[^WШљ[‚€^WШљ[ЏH‰
]XЭЮ^WШљ[ЉH‚‚€ЪXЪЧЬЬќШ]Z[X›WЩ›Ь—Ю^B‚€ШШ[Щ\ќ™\—ШY€]ZYЩ^\Z\€љ]]WЪЩ^HX›XЧЪЩ^HЪЬќЪY€Щ\ќ™\—ШYЏH‰
]XЭЬЩ\ќ™\—ШYЉH‚€]ZYH‰
‰Ю^WШљ[џH€]ZY
H‚€Щ^\Z\ЏH‰
‰Ю^WШљ[џH€ЌMLNJH‚€љ]]WЪЩ^OH‰
љ[ќ€	Й\Ч‰И‰ЪЩ^\Z\џH€]ЪИQ‰О€
‰И	ЭЫЭЩ\Љ	JH€Ьљ]]KИЬљ[ќ	ЋИ^]IКH‚€X›XЧЪЩ^OH‰
љ[ќ€	Й\Ч‰И‰ЪЩ^\Z\џH€]ЪИQ‰О€
‰И	ЭЫЭЩ\Љ	JH€ЬX›XЯ\ЬЭЫЬ™ИЬљ[ќ	ЋИ^]IКH‚€ЪЬќЪYH‰
Ь[њЬЫ[™Z^
H‚‚€Y€ЦИ^€‰Ьљ]]WЪЩ^_H€^€‰ЬX›XЧЪЩ^_H€WNИ[‚€YH‘Z[YИЩ[™\]H‘PSUHЌMLNHЩ^HZ\‹€‚€љB‚€ZЩ\€\‰
\›[YH‰РУУ‘’QЧФUHЉH‚€Y€ЦИY€‰РУУ‘’QЧФUH€WNИ[‚€ЬXH‰РУУ‘’QЧФUH€‰РУУ‘’QЧФUKZЛ‰
]H
ЙVI[IY	R	SITКH‚€љB‚€ШШ[Щ\ќ™\—Ы[YWЪњЫЫ€\™Щ]ЪњЫЫ€љ]]WЪЩ^WЪњЫЫ€]ZYЪњЫЫ€[XZ[ЪњЫЫ€ЪЬќЪYЪњЫЫ‚€Щ\ќ™\—Ы[YWЪњЫЫЏH‰
њЫЫ—Щ\ШШ\H‰ФСT•‘T—УђSQ_HЉH‚€\™Щ]ЪњЫЫЏH‰
њЫЫ—Щ\ШШ\H‰ХT‘СUHЉH‚€љ]]WЪЩ^WЪњЫЫЏH‰
њЫЫ—Щ\ШШ\H‰Ьљ]]WЪЩ^_HЉH‚€]ZYЪњЫЫЏH‰
њЫЫ—Щ\ШШ\H‰Э]ZYHЉH‚€[XZ[ЪњЫЫЏH‰
њЫЫ—Щ\ШШ\H‰СSPRSHЉH‚€ЪЬќЪYЪњЫЫЏH‰
њЫЫ—Щ\ШШ\H‰ЬЪЬќЪYHЉH‚‚€Ш]€‰РУУ‘’QЧФUH€SС‚ћВ€›ЩИЋ€В€›ЩЫ]™[Ћ€ќШ\›љ[™И‚€K€љ[›Э[™ИЋ€В€В€ќYИЋ€ќ›\ЬЛ\™X[]KZ[€‹€›\Э[€Ћ€ЊЊЊЊ‹€њЬќЋ€	ФФ•K€њ›ЭШЫЫЋ€ќ›\ЬИ‹€њЩ][™ЬИЋ€В€ЫY[ќИЋ€В€В€љYЋ€‰Э]ZYЪњЫЫџH‹€™›ЭИЋ€ћЛ\њћ]љ\Ъ[Ы€‹€™[XZ[Ћ€‰Щ[XZ[ЪњЫЫџH‚€B€K€™XЬћ\[Ы€Ћ€››Ы™H‚€K€њЭ™X[TЩ][™ЬИЋ€В€›™]ЫЬљИЋ€њ]И‹€њЩXЭ\љ]HЋ€њ™X[]H‹€њ™X[]TЩ][™ЬИЋ€В€њЪЭИЋ€[ЩK€ќ\™Щ]Ћ€‰Э\™Щ]ЪњЫЫџH‹€њЩ\ќ™\“[Y\ИЋ€В€‰ЬЩ\ќ™\—Ы[YWЪњЫЫџH‚€K€њљ]]RЩ^HЋ€‰Ьљ]]WЪЩ^WЪњЫЫџH‹€њЪЬќYИЋ€В€‰ЬЪЬќЪYЪњЫЫџH‚€K€ћ™\€Ћ€€B€B€B€K€›Э]›Э[™ИЋ€В€В€ќYИЋ€™\™XЭ‹€њ›ЭШЫЫЋ€™њ™YYЫH‚€B€BџB‘SС‚‚€ЫЫ™љYЭ\™WЮ^WЬЩ\ќљXЩB‚€ЩИ•\Э[™И^HЫЫ™љYЭ\][Ы‹‹‹€‚€\ЭЮ^WШЫЫ™љYИ‰Ю^WШљ[џH‚‚€ЩИ“Ь[љ[™Иљ\™]Ш[ЬќY€HЭ\ЬќYљ\™]Ш[\ИXЭ]™K‹‹€‚€Ь[—Щљ\™]Ш[ЬЬќ‚€ЫЫ™љYЭ\™WЫ™]ЫЬљЧЬЭXЪВ‚€ЩИ”Э\ќ[™И^K‹‹€‚€™\Э\ќШ[™Э™\љYћWЮ^B‚€Ьљ]WЭ[љ[™ЧЬ™\Ьќ‚€ШШ[\љB€\љOH‰
XZЩWЭ›\ЬЧЭ\љH‰Э]ZYH€‰ЬЩ\ќ™\—ШYџH€‰ЬX›XЧЪЩ^_H€‰ЬЪЬќЪYHЉH‚€Ьљ]WШЫY[ќЪ[™›И‰Э\љ_H€‰ЬЩ\ќ™\—ШYџH€‰Э]ZYH€‰ЬX›XЧЪЩ^_H€‰ЬЪЬќЪYH‚‚€XЪВ€XЪИ‘Ы™K€‚€XЪИђЫY[ќ\[Y]\њИШ]™YО€	РУQS•ТS‘“ЧФUH‚€XЪИ•[љ[™И™\ЬќШ]™YО€	ХS’S‘ЧФ‘TФ•ФUH‚€XЪВ€Ш]‰РУQS•ТS‘“ЧФUH‚џB‚›XZ[€‰‚