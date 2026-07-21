#!/usr/bin/env bash
set -Eeuo pipefail

# x420-fastpath
# A single-file, transactional VLESS + REALITY + Vision installer and
# measurement-driven Linux network tuner for Debian/Ubuntu systemd hosts.

PROGRAM_NAME="$(basename "$0")"
readonly PROGRAM_NAME
readonly PROGRAM_VERSION="1.0.0"
readonly DEFAULT_XRAY_VERSION="v26.3.27"

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
readonly XRAY_CLIENT_FILE="${XRAY_CONFIG_DIR}/client.json"
readonly LEGACY_PARAM_FILE="${XRAY_CONFIG_DIR}/vless-reality.env"
readonly XRAY_UNIT="/etc/systemd/system/xray.service"

readonly STATE_DIR="/var/lib/x420-fastpath"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly LOCK_FILE="${STATE_DIR}/lock"
readonly LAST_INSTALL_BACKUP="${STATE_DIR}/last-install-backup"
readonly LAST_TUNE_BACKUP="${STATE_DIR}/last-tune-backup"

readonly SYSCTL_FILE="/etc/sysctl.d/99-z-x420-fastpath.conf"
readonly QDISC_APPLY_SCRIPT="/usr/local/libexec/x420-apply-qdisc"
readonly QDISC_UNIT="/etc/systemd/system/x420-fastpath-qdisc.service"

WORK_DIR=""
INSTALL_TRANSACTION=""
TUNE_TRANSACTION=""
EXIT_HANDLER_ACTIVE="0"

info() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
${PROGRAM_NAME} ${PROGRAM_VERSION}

Purpose:
  Install the shortest practical Xray data path:
    RAW/TCP -> REALITY -> VLESS Vision -> freedom
  Then measure and tune the Linux host without mixing destructive cleanup into
  the protocol installer.

Usage:
  sudo ./${PROGRAM_NAME} install --sni DOMAIN [install options]
  ./${PROGRAM_NAME} probe
  sudo ./${PROGRAM_NAME} tune [tune options]
  ./${PROGRAM_NAME} benchmark server [benchmark-server options]
  ./${PROGRAM_NAME} benchmark client [benchmark-client options]
  ./${PROGRAM_NAME} status [--show-client]
  sudo ./${PROGRAM_NAME} rollback install|tune|all

Install options:
  --sni DOMAIN              REALITY serverName. Required on first install.
  --target HOST:PORT        REALITY target. Default: <sni>:443.
  --address ADDRESS         Public address placed in the client URI.
  --listen ADDRESS          Listen address. Default: 0.0.0.0.
  --port PORT               Listen port. Default: 443.
  --name NAME               Client profile name. Default: vless-reality-fastpath.
  --uuid UUID               Reuse an explicit VLESS UUID.
  --short-id HEX            Explicit REALITY short ID, 2-16 even hex chars.
  --private-key KEY         Explicit REALITY X25519 private key.
  --public-key KEY          Expected public key/password; mismatch is rejected.
  --rotate-credentials      Generate a new UUID, key pair, and short ID.
  --xray-version VERSION    Pinned release tag. Default: ${DEFAULT_XRAY_VERSION}.
  --log-level LEVEL         warning, error, or none. Default: warning.
  --enable-tfo              Put tcpFastOpen on Xray inbound and direct outbound.
  --disable-tfo             Explicitly remove tcpFastOpen from Xray config.
  --open-firewall           Open the TCP port in active UFW/firewalld.
  --skip-target-check       Skip the best-effort TLS 1.3 target preflight.
  --no-start                Install and validate files without starting Xray.

Tune options:
  --profile PROFILE         balanced, throughput, or latency. Default: balanced.
  --bandwidth-mbps N        Expected path bandwidth; requires --rtt-ms.
  --rtt-ms N                Expected path RTT; requires --bandwidth-mbps.
  --congestion NAME         bbr, cubic, or reno. Default: bbr.
  --qdisc NAME              fq, fq_codel, or cake. Default: fq.
  --high-concurrency        Raise queues/ephemeral capacity intentionally.
  --enable-tfo              Enable Linux client+server TFO bitmap (value 3).
  --no-live-qdisc           Persist qdisc choice but do not replace it now.

Benchmark server options:
  --duration SECONDS        Sampling window, 5-60 seconds. Default: 15.
  --interface NAME          Interface to sample. Default: default-route device.

Benchmark client options:
  --url URL                 Stable download URL used by both paths. Required.
  --proxy URL               Local Xray proxy, e.g. socks5h://127.0.0.1:10808.
  --rounds N                Alternating direct/proxy rounds, 1-20. Default: 5.
  --max-time SECONDS        Per-request timeout. Default: 60.
  --output FILE             Optional CSV output path.

Examples:
  sudo ./${PROGRAM_NAME} install \
    --sni www.example.com --target www.example.com:443 --address 203.0.113.10

  sudo ./${PROGRAM_NAME} tune \
    --profile throughput --bandwidth-mbps 1000 --rtt-ms 100

  ./${PROGRAM_NAME} benchmark client \
    --url 'https://speed.cloudflare.com/__down?bytes=100000000' \
    --proxy socks5h://127.0.0.1:10808

Notes:
  * install never deletes nginx, caddy, sing-box, or another proxy stack.
  * tune changes host-wide kernel state, but records a rollback snapshot first.
  * client.json contains the UUID and must be treated as a credential.
USAGE
}

need_value() {
  local option="$1"
  local count="$2"
  (( count >= 2 )) || fail "${option} requires a value"
}

require_root() {
  (( EUID == 0 )) || fail "This command must run as root. Use sudo."
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || fail "This command supports Linux only."
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required."
  [[ -d /run/systemd/system ]] || fail "systemd is not running as PID 1."
}

make_work_dir() {
  if [[ -z "${WORK_DIR}" ]]; then
    WORK_DIR="$(mktemp -d /tmp/x420-fastpath.XXXXXXXX)"
  fi
}

cleanup_work_dir() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    case "${WORK_DIR}" in
      /tmp/x420-fastpath.*)
        rm -rf -- "${WORK_DIR}"
        ;;
      *)
        warn "Refusing to remove unexpected temporary path: ${WORK_DIR}"
        ;;
    esac
  fi
}

ensure_state_dirs() {
  install -d -o root -g root -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"
}

acquire_lock() {
  ensure_state_dirs
  command -v flock >/dev/null 2>&1 || fail "flock is required (package: util-linux)."
  exec 9>"${LOCK_FILE}"
  flock -n 9 || fail "Another ${PROGRAM_NAME} mutation is already running."
}

backup_path() {
  local source_path="$1"
  local backup_name="$2"
  local destination_dir="$3"

  if [[ -e "${source_path}" || -L "${source_path}" ]]; then
    cp -a -- "${source_path}" "${destination_dir}/${backup_name}"
  else
    : > "${destination_dir}/${backup_name}.absent"
  fi
}

restore_path() {
  local target_path="$1"
  local backup_name="$2"
  local source_dir="$3"

  if [[ -e "${source_dir}/${backup_name}.absent" ]]; then
    rm -f -- "${target_path}"
  elif [[ -e "${source_dir}/${backup_name}" || -L "${source_dir}/${backup_name}" ]]; then
    rm -f -- "${target_path}"
    cp -a -- "${source_dir}/${backup_name}" "${target_path}"
  fi
}

read_pointer() {
  local pointer_file="$1"
  [[ -s "${pointer_file}" ]] || return 1
  sed -n '1p' "${pointer_file}"
}

write_pointer() {
  local pointer_file="$1"
  local value="$2"
  local temporary="${pointer_file}.new.$$"
  printf '%s\n' "${value}" > "${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${pointer_file}"
}

restore_install_backup() {
  local snapshot="$1"
  [[ -d "${snapshot}" ]] || {
    warn "Install rollback snapshot is missing: ${snapshot}"
    return 1
  }

  info "Restoring install snapshot ${snapshot}"
  systemctl stop xray.service >/dev/null 2>&1 || true

  restore_path "${XRAY_BIN}" xray.bin "${snapshot}"
  restore_path "${XRAY_CONFIG_FILE}" config.json "${snapshot}"
  restore_path "${XRAY_CLIENT_FILE}" client.json "${snapshot}"
  restore_path "${XRAY_UNIT}" xray.service "${snapshot}"

  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ -f "${snapshot}/service.enabled" ]]; then
    systemctl enable xray.service >/dev/null 2>&1 || true
  else
    systemctl disable xray.service >/dev/null 2>&1 || true
  fi

  if [[ -f "${snapshot}/service.active" && -f "${XRAY_UNIT}" ]]; then
    systemctl restart xray.service >/dev/null 2>&1 || true
  fi
}

restore_qdisc_snapshot() {
  local snapshot_file="$1"
  local dev relation parent kind
  [[ -s "${snapshot_file}" ]] || return 0
  command -v tc >/dev/null 2>&1 || return 0

  while IFS='|' read -r dev relation parent kind; do
    [[ "${relation}" == "root" ]] || continue
    case "${kind}" in
      ""|noqueue)
        tc qdisc del dev "${dev}" root >/dev/null 2>&1 || true
        ;;
      *)
        tc qdisc replace dev "${dev}" root "${kind}" >/dev/null 2>&1 || true
        ;;
    esac
  done < "${snapshot_file}"

  while IFS='|' read -r dev relation parent kind; do
    [[ "${relation}" == "parent" && -n "${parent}" && -n "${kind}" ]] || continue
    tc qdisc replace dev "${dev}" parent "${parent}" "${kind}" >/dev/null 2>&1 || true
  done < "${snapshot_file}"
}

restore_tune_backup() {
  local snapshot="$1"
  local key value
  [[ -d "${snapshot}" ]] || {
    warn "Tune rollback snapshot is missing: ${snapshot}"
    return 1
  }

  info "Restoring tuning snapshot ${snapshot}"
  systemctl stop x420-fastpath-qdisc.service >/dev/null 2>&1 || true

  restore_path "${SYSCTL_FILE}" sysctl.conf "${snapshot}"
  restore_path "${QDISC_APPLY_SCRIPT}" apply-qdisc "${snapshot}"
  restore_path "${QDISC_UNIT}" qdisc.service "${snapshot}"

  if [[ -s "${snapshot}/sysctl.before" ]]; then
    while IFS=$'\t' read -r key value; do
      [[ -n "${key}" ]] || continue
      sysctl -q -w "${key}=${value}" >/dev/null 2>&1 || warn "Could not restore ${key}"
    done < "${snapshot}/sysctl.before"
  fi

  restore_qdisc_snapshot "${snapshot}/qdisc.before"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ -f "${snapshot}/qdisc-unit.enabled" && -f "${QDISC_UNIT}" ]]; then
    systemctl enable x420-fastpath-qdisc.service >/dev/null 2>&1 || true
  else
    systemctl disable x420-fastpath-qdisc.service >/dev/null 2>&1 || true
  fi

  if [[ -f "${snapshot}/qdisc-unit.active" && -f "${QDISC_UNIT}" ]]; then
    systemctl start x420-fastpath-qdisc.service >/dev/null 2>&1 || true
  fi
}

on_exit() {
  local rc=$?
  (( EXIT_HANDLER_ACTIVE == 0 )) || return
  EXIT_HANDLER_ACTIVE="1"
  trap - EXIT
  set +e

  if [[ "${rc}" -ne 0 && -n "${INSTALL_TRANSACTION}" ]]; then
    warn "Install transaction failed; restoring the previous state."
    restore_install_backup "${INSTALL_TRANSACTION}"
  fi

  if [[ "${rc}" -ne 0 && -n "${TUNE_TRANSACTION}" ]]; then
    warn "Tune transaction failed; restoring the previous kernel state."
    restore_tune_backup "${TUNE_TRANSACTION}"
  fi

  cleanup_work_dir
  exit "${rc}"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

install_dependencies() {
  require_linux
  require_systemd
  command -v apt-get >/dev/null 2>&1 || fail "This release supports Debian/Ubuntu with apt-get."

  info "Installing required Debian/Ubuntu packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates coreutils curl ethtool iproute2 jq openssl procps unzip util-linux
}

detect_xray_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo 64 ;;
    aarch64|arm64) echo arm64-v8a ;;
    armv7l|armv7*) echo arm32-v7a ;;
    armv6l) echo arm32-v6 ;;
    armv5l) echo arm32-v5 ;;
    i386|i686) echo 32 ;;
    loongarch64) echo loong64 ;;
    riscv64) echo riscv64 ;;
    s390x) echo s390x ;;
    ppc64le) echo ppc64le ;;
    ppc64) echo ppc64 ;;
    *) fail "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

pinned_sha256() {
  local version="$1"
  local arch="$2"
  case "${version}:${arch}" in
    v26.3.27:64)
      echo 23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
      ;;
    v26.3.27:arm64-v8a)
      echo 4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c
      ;;
    *)
      return 1
      ;;
  esac
}

download_xray() {
  local version="$1"
  local destination="$2"
  local arch asset base_url zip_file digest_file expected actual

  arch="$(detect_xray_arch)"
  asset="Xray-linux-${arch}.zip"
  base_url="https://github.com/XTLS/Xray-core/releases/download/${version}"
  zip_file="${WORK_DIR}/${asset}"
  digest_file="${zip_file}.dgst"

  info "Downloading Xray ${version} for ${arch}"
  curl --fail --location --retry 3 --retry-delay 1 --retry-connrefused \
    --connect-timeout 15 --proto '=https' --tlsv1.2 \
    --output "${zip_file}" "${base_url}/${asset}"

  if expected="$(pinned_sha256 "${version}" "${arch}" 2>/dev/null)"; then
    info "Using the SHA-256 pinned inside this script"
  else
    curl --fail --location --retry 3 --retry-delay 1 --retry-connrefused \
      --connect-timeout 15 --proto '=https' --tlsv1.2 \
      --output "${digest_file}" "${base_url}/${asset}.dgst"
    expected="$(awk -F'= *' '$1 == "SHA2-256" {print tolower($2); exit}' "${digest_file}")"
  fi

  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || fail "Release SHA-256 is missing or malformed."
  actual="$(sha256sum "${zip_file}" | awk '{print tolower($1)}')"
  [[ "${actual}" == "${expected}" ]] || fail "Xray archive SHA-256 mismatch."

  install -d -m 0700 "${WORK_DIR}/xray-unpack"
  unzip -q "${zip_file}" xray -d "${WORK_DIR}/xray-unpack"
  install -m 0755 "${WORK_DIR}/xray-unpack/xray" "${destination}"
  "${destination}" version >/dev/null
}

default_route_devs() {
  local devices
  devices="$(ip -o route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") print $(i+1)}' | sort -u)"
  if [[ -z "${devices}" ]]; then
    devices="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi
  [[ -n "${devices}" ]] || return 1
  printf '%s\n' "${devices}"
}

atomic_install_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"
  local owner="$4"
  local group="$5"
  local staged_file="${target_file}.x420-new.$$"

  install -o "${owner}" -g "${group}" -m "${mode}" "${source_file}" "${staged_file}"
  mv -f -- "${staged_file}" "${target_file}"
}

create_xray_user_and_dirs() {
  if ! id xray >/dev/null 2>&1; then
    info "Creating the xray system user"
    useradd --system --home-dir /var/lib/xray --create-home --shell /usr/sbin/nologin xray
  fi

  install -d -o root -g xray -m 0750 "${XRAY_CONFIG_DIR}"
  install -d -o root -g root -m 0755 "$(dirname "${XRAY_BIN}")"
}

json_first_vless() {
  local expression="$1"
  jq -r "[.inbounds[]? | select(.protocol == \"vless\")][0]${expression} // empty" \
    "${XRAY_CONFIG_FILE}" 2>/dev/null || true
}

legacy_value() {
  local key="$1"
  [[ -f "${LEGACY_PARAM_FILE}" ]] || return 0
  awk -F= -v wanted="${key}" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "${LEGACY_PARAM_FILE}"
}

INSTALL_SNI=""
INSTALL_TARGET=""
INSTALL_ADDRESS=""
INSTALL_LISTEN=""
INSTALL_PORT=""
INSTALL_NAME=""
INSTALL_UUID=""
INSTALL_SHORT_ID=""
INSTALL_PRIVATE_KEY=""
INSTALL_PUBLIC_KEY=""
INSTALL_XRAY_VERSION="${DEFAULT_XRAY_VERSION}"
INSTALL_LOG_LEVEL=""
INSTALL_TFO_MODE="inherit"
INSTALL_ROTATE="0"
INSTALL_OPEN_FIREWALL="0"
INSTALL_SKIP_TARGET_CHECK="0"
INSTALL_NO_START="0"

SNI_SET="0"
TARGET_SET="0"
ADDRESS_SET="0"
LISTEN_SET="0"
PORT_SET="0"
NAME_SET="0"
UUID_SET="0"
SHORT_ID_SET="0"
PRIVATE_KEY_SET="0"
PUBLIC_KEY_SET="0"
LOG_LEVEL_SET="0"

parse_install_args() {
  while (( $# > 0 )); do
    case "$1" in
      --sni)
        need_value "$1" "$#"
        INSTALL_SNI="$2"; SNI_SET="1"; shift 2
        ;;
      --target|--dest)
        need_value "$1" "$#"
        INSTALL_TARGET="$2"; TARGET_SET="1"; shift 2
        ;;
      --address)
        need_value "$1" "$#"
        INSTALL_ADDRESS="$2"; ADDRESS_SET="1"; shift 2
        ;;
      --listen)
        need_value "$1" "$#"
        INSTALL_LISTEN="$2"; LISTEN_SET="1"; shift 2
        ;;
      --port)
        need_value "$1" "$#"
        INSTALL_PORT="$2"; PORT_SET="1"; shift 2
        ;;
      --name)
        need_value "$1" "$#"
        INSTALL_NAME="$2"; NAME_SET="1"; shift 2
        ;;
      --uuid)
        need_value "$1" "$#"
        INSTALL_UUID="$2"; UUID_SET="1"; shift 2
        ;;
      --short-id)
        need_value "$1" "$#"
        INSTALL_SHORT_ID="$2"; SHORT_ID_SET="1"; shift 2
        ;;
      --private-key)
        need_value "$1" "$#"
        INSTALL_PRIVATE_KEY="$2"; PRIVATE_KEY_SET="1"; shift 2
        ;;
      --public-key)
        need_value "$1" "$#"
        INSTALL_PUBLIC_KEY="$2"; PUBLIC_KEY_SET="1"; shift 2
        ;;
      --xray-version)
        need_value "$1" "$#"
        INSTALL_XRAY_VERSION="$2"; shift 2
        ;;
      --log-level)
        need_value "$1" "$#"
        INSTALL_LOG_LEVEL="$2"; LOG_LEVEL_SET="1"; shift 2
        ;;
      --rotate-credentials)
        INSTALL_ROTATE="1"; shift
        ;;
      --enable-tfo)
        INSTALL_TFO_MODE="on"; shift
        ;;
      --disable-tfo)
        INSTALL_TFO_MODE="off"; shift
        ;;
      --open-firewall)
        INSTALL_OPEN_FIREWALL="1"; shift
        ;;
      --skip-target-check)
        INSTALL_SKIP_TARGET_CHECK="1"; shift
        ;;
      --no-start)
        INSTALL_NO_START="1"; shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        fail "Unknown install option: $1"
        ;;
    esac
  done
}

load_existing_install_defaults() {
  local value existing_tfo
  [[ -f "${XRAY_CONFIG_FILE}" ]] || return 0

  info "Reusing unspecified values from the existing Xray configuration"

  if [[ "${SNI_SET}" == "0" ]]; then
    INSTALL_SNI="$(json_first_vless '.streamSettings.realitySettings.serverNames[0]')"
  fi
  if [[ "${TARGET_SET}" == "0" ]]; then
    INSTALL_TARGET="$(json_first_vless '.streamSettings.realitySettings | (.target // .dest)')"
  fi
  if [[ "${LISTEN_SET}" == "0" ]]; then
    INSTALL_LISTEN="$(json_first_vless '.listen')"
  fi
  if [[ "${PORT_SET}" == "0" ]]; then
    INSTALL_PORT="$(json_first_vless '.port')"
  fi
  if [[ "${UUID_SET}" == "0" && "${INSTALL_ROTATE}" == "0" ]]; then
    INSTALL_UUID="$(json_first_vless '.settings.clients[0].id')"
  fi
  if [[ "${SHORT_ID_SET}" == "0" && "${INSTALL_ROTATE}" == "0" ]]; then
    INSTALL_SHORT_ID="$(json_first_vless '.streamSettings.realitySettings.shortIds[0]')"
  fi
  if [[ "${PRIVATE_KEY_SET}" == "0" && "${INSTALL_ROTATE}" == "0" ]]; then
    INSTALL_PRIVATE_KEY="$(json_first_vless '.streamSettings.realitySettings.privateKey')"
  fi
  if [[ "${LOG_LEVEL_SET}" == "0" ]]; then
    value="$(jq -r '.log.loglevel // empty' "${XRAY_CONFIG_FILE}" 2>/dev/null || true)"
    [[ -z "${value}" ]] || INSTALL_LOG_LEVEL="${value}"
  fi

  if [[ "${INSTALL_TFO_MODE}" == "inherit" ]]; then
    existing_tfo="$(json_first_vless '.streamSettings.sockopt.tcpFastOpen')"
    case "${existing_tfo}" in
      true|[1-9]*) INSTALL_TFO_MODE="on" ;;
      *) INSTALL_TFO_MODE="off" ;;
    esac
  fi

  if [[ "${ADDRESS_SET}" == "0" ]]; then
    if [[ -f "${XRAY_CLIENT_FILE}" ]]; then
      INSTALL_ADDRESS="$(jq -r '.address // empty' "${XRAY_CLIENT_FILE}" 2>/dev/null || true)"
    fi
    [[ -n "${INSTALL_ADDRESS}" ]] || INSTALL_ADDRESS="$(legacy_value CLIENT_ADDRESS)"
  fi

  if [[ "${NAME_SET}" == "0" ]]; then
    if [[ -f "${XRAY_CLIENT_FILE}" ]]; then
      INSTALL_NAME="$(jq -r '.name // empty' "${XRAY_CLIENT_FILE}" 2>/dev/null || true)"
    fi
  fi
}

finalize_install_defaults() {
  [[ -n "${INSTALL_LISTEN}" ]] || INSTALL_LISTEN="0.0.0.0"
  [[ -n "${INSTALL_PORT}" ]] || INSTALL_PORT="443"
  [[ -n "${INSTALL_NAME}" ]] || INSTALL_NAME="vless-reality-fastpath"
  [[ -n "${INSTALL_LOG_LEVEL}" ]] || INSTALL_LOG_LEVEL="warning"
  [[ "${INSTALL_TFO_MODE}" != "inherit" ]] || INSTALL_TFO_MODE="off"

  [[ -n "${INSTALL_SNI}" ]] || fail "--sni is required on the first install."
  [[ -n "${INSTALL_TARGET}" ]] || INSTALL_TARGET="${INSTALL_SNI}:443"

  if [[ "${INSTALL_ROTATE}" == "1" ]]; then
    (( UUID_SET == 0 && SHORT_ID_SET == 0 && PRIVATE_KEY_SET == 0 && PUBLIC_KEY_SET == 0 )) || \
      fail "--rotate-credentials cannot be combined with explicit credential options."
    INSTALL_UUID=""
    INSTALL_SHORT_ID=""
    INSTALL_PRIVATE_KEY=""
    INSTALL_PUBLIC_KEY=""
  fi
}

validate_target_format() {
  local target="$1"
  local target_port=""
  if [[ "${target}" =~ ^\[[0-9A-Fa-f:]+\]:([0-9]+)$ ]]; then
    target_port="${BASH_REMATCH[1]}"
  elif [[ "${target}" =~ ^[A-Za-z0-9._-]+:([0-9]+)$ ]]; then
    target_port="${BASH_REMATCH[1]}"
  else
    fail "--target must be HOST:PORT or [IPv6]:PORT."
  fi
  target_port=$((10#${target_port}))
  (( target_port >= 1 && target_port <= 65535 )) || fail "REALITY target port is outside 1-65535."
}

validate_install_values() {
  [[ "${INSTALL_XRAY_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "--xray-version must look like v26.3.27."
  [[ "${INSTALL_PORT}" =~ ^[0-9]+$ ]] || fail "--port must be numeric."
  INSTALL_PORT=$((10#${INSTALL_PORT}))
  (( INSTALL_PORT >= 1 && INSTALL_PORT <= 65535 )) || fail "--port is outside 1-65535."
  [[ "${INSTALL_SNI}" =~ ^[A-Za-z0-9._:-]{1,253}$ ]] || fail "--sni is malformed."
  [[ "${INSTALL_LISTEN}" =~ ^[A-Za-z0-9._:%-]+$ ]] || fail "--listen is malformed."
  if [[ -n "${INSTALL_ADDRESS}" ]]; then
    [[ "${INSTALL_ADDRESS}" =~ ^\[?[A-Za-z0-9._:%-]+\]?$ ]] || fail "--address is malformed."
  fi
  [[ -n "${INSTALL_NAME}" && "${INSTALL_NAME}" != *$'\n'* ]] || fail "--name is malformed."
  [[ "${INSTALL_LOG_LEVEL}" =~ ^(warning|error|none)$ ]] || \
    fail "--log-level must be warning, error, or none."
  validate_target_format "${INSTALL_TARGET}"

  if [[ -n "${INSTALL_UUID}" ]]; then
    [[ "${INSTALL_UUID}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || \
      fail "The VLESS UUID is malformed."
  fi

  if [[ -n "${INSTALL_SHORT_ID}" ]]; then
    [[ "${INSTALL_SHORT_ID}" =~ ^[0-9A-Fa-f]{2,16}$ ]] || \
      fail "The REALITY short ID must contain 2-16 hexadecimal characters."
    (( ${#INSTALL_SHORT_ID} % 2 == 0 )) || fail "The REALITY short ID length must be even."
    INSTALL_SHORT_ID="$(printf '%s' "${INSTALL_SHORT_ID}" | tr '[:upper:]' '[:lower:]')"
  fi

  if [[ -n "${INSTALL_PUBLIC_KEY}" && -z "${INSTALL_PRIVATE_KEY}" ]]; then
    fail "--public-key requires a private key from either --private-key or the existing config."
  fi
}

parse_key_output() {
  local label="$1"
  awk -F': *' -v wanted="${label}" '
    wanted == "private" && ($1 == "PrivateKey" || $1 == "Private key") {print $2; exit}
    wanted == "public" && ($1 ~ /^Password/ || $1 == "PublicKey" || $1 == "Public key") {print $2; exit}
  '
}

generate_or_verify_credentials() {
  local staged_xray="$1"
  local output derived_public

  if [[ -z "${INSTALL_UUID}" ]]; then
    INSTALL_UUID="$("${staged_xray}" uuid)"
  fi

  if [[ -z "${INSTALL_PRIVATE_KEY}" ]]; then
    output="$("${staged_xray}" x25519)"
    INSTALL_PRIVATE_KEY="$(parse_key_output private <<<"${output}")"
    INSTALL_PUBLIC_KEY="$(parse_key_output public <<<"${output}")"
  else
    output="$("${staged_xray}" x25519 -i "${INSTALL_PRIVATE_KEY}")"
    derived_public="$(parse_key_output public <<<"${output}")"
    [[ -n "${derived_public}" ]] || fail "Could not derive the REALITY public key/password."
    if [[ -n "${INSTALL_PUBLIC_KEY}" && "${INSTALL_PUBLIC_KEY}" != "${derived_public}" ]]; then
      fail "The supplied REALITY public key does not match the private key."
    fi
    INSTALL_PUBLIC_KEY="${derived_public}"
  fi

  [[ -n "${INSTALL_PRIVATE_KEY}" && -n "${INSTALL_PUBLIC_KEY}" ]] || \
    fail "Could not parse the X25519 key pair from Xray."

  if [[ -z "${INSTALL_SHORT_ID}" ]]; then
    INSTALL_SHORT_ID="$(openssl rand -hex 8)"
  fi

  validate_install_values
}

detect_client_address() {
  local candidate=""
  [[ -n "${INSTALL_ADDRESS}" ]] && return 0

  candidate="$(curl -fsS --max-time 8 --proto '=https' https://api.ipify.org 2>/dev/null || true)"
  candidate="${candidate//$'\r'/}"
  candidate="${candidate//$'\n'/}"
  if [[ "${candidate}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    INSTALL_ADDRESS="${candidate}"
  fi

  [[ -n "${INSTALL_ADDRESS}" ]] || \
    fail "Could not determine a public IP. Pass --address explicitly."
}

preflight_reality_target() {
  local output_file="${WORK_DIR}/target-check.log"
  [[ "${INSTALL_SKIP_TARGET_CHECK}" == "0" ]] || return 0

  info "Checking whether the REALITY target negotiates TLS 1.3"
  if timeout 12 openssl s_client -brief -tls1_3 \
      -connect "${INSTALL_TARGET}" -servername "${INSTALL_SNI}" \
      </dev/null >"${output_file}" 2>&1 && grep -q 'TLSv1.3' "${output_file}"; then
    info "REALITY target TLS 1.3 preflight passed"
  else
    warn "Target preflight did not confirm TLS 1.3. Review ${INSTALL_TARGET}/${INSTALL_SNI}."
    warn "Installation continues because some targets reject synthetic preflight connections."
  fi
}

uri_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

uri_host() {
  local address="$1"
  if [[ "${address}" == *:* && "${address}" != \[*\] ]]; then
    printf '[%s]' "${address}"
  else
    printf '%s' "${address}"
  fi
}

render_xray_config() {
  local destination="$1"
  local tfo_json="false"
  [[ "${INSTALL_TFO_MODE}" == "on" ]] && tfo_json="true"

  jq -n \
    --arg listen "${INSTALL_LISTEN}" \
    --argjson port "${INSTALL_PORT}" \
    --arg uuid "${INSTALL_UUID}" \
    --arg sni "${INSTALL_SNI}" \
    --arg target "${INSTALL_TARGET}" \
    --arg private_key "${INSTALL_PRIVATE_KEY}" \
    --arg short_id "${INSTALL_SHORT_ID}" \
    --arg log_level "${INSTALL_LOG_LEVEL}" \
    --argjson tfo "${tfo_json}" '
      {
        log: {loglevel: $log_level},
        inbounds: [
          {
            tag: "vless-reality-in",
            listen: $listen,
            port: $port,
            protocol: "vless",
            settings: {
              clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
              decryption: "none"
            },
            streamSettings: (
              {
                network: "raw",
                security: "reality",
                realitySettings: {
                  show: false,
                  target: $target,
                  xver: 0,
                  serverNames: [$sni],
                  privateKey: $private_key,
                  shortIds: [$short_id]
                }
              }
              + if $tfo then {sockopt: {tcpFastOpen: true}} else {} end
            )
          }
        ],
        outbounds: [
          (
            {tag: "direct", protocol: "freedom"}
            + if $tfo then {streamSettings: {sockopt: {tcpFastOpen: true}}} else {} end
          )
        ]
      }
    ' > "${destination}"
}

render_systemd_unit() {
  local destination="$1"
  cat > "${destination}" <<UNIT
[Unit]
Description=Xray VLESS REALITY Vision Fast Path
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
UMask=0027
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartSec=2s
TimeoutStopSec=15s
LimitNOFILE=1048576
TasksMax=infinity

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectHostname=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadOnlyPaths=${XRAY_CONFIG_FILE}

[Install]
WantedBy=multi-user.target
UNIT
}

render_client_file() {
  local destination="$1"
  local encoded_sni encoded_name encoded_public encoded_sid host uri

  encoded_sni="$(uri_encode "${INSTALL_SNI}")"
  encoded_name="$(uri_encode "${INSTALL_NAME}")"
  encoded_public="$(uri_encode "${INSTALL_PUBLIC_KEY}")"
  encoded_sid="$(uri_encode "${INSTALL_SHORT_ID}")"
  host="$(uri_host "${INSTALL_ADDRESS}")"
  uri="vless://${INSTALL_UUID}@${host}:${INSTALL_PORT}?encryption=none&security=reality&sni=${encoded_sni}&fp=chrome&pbk=${encoded_public}&sid=${encoded_sid}&type=tcp&flow=xtls-rprx-vision&spx=%2F#${encoded_name}"

  jq -n \
    --arg name "${INSTALL_NAME}" \
    --arg address "${INSTALL_ADDRESS}" \
    --argjson port "${INSTALL_PORT}" \
    --arg sni "${INSTALL_SNI}" \
    --arg target "${INSTALL_TARGET}" \
    --arg uuid "${INSTALL_UUID}" \
    --arg password "${INSTALL_PUBLIC_KEY}" \
    --arg short_id "${INSTALL_SHORT_ID}" \
    --arg uri "${uri}" '
      {
        name: $name,
        address: $address,
        port: $port,
        sni: $sni,
        target: $target,
        uuid: $uuid,
        realityPassword: $password,
        shortId: $short_id,
        flow: "xtls-rprx-vision",
        transport: "tcp",
        fingerprint: "chrome",
        mux: false,
        uri: $uri
      }
    ' > "${destination}"
}

check_port_conflict() {
  local listener
  listener="$(ss -H -ltn "sport = :${INSTALL_PORT}" 2>/dev/null || true)"
  [[ -z "${listener}" ]] && return 0

  if systemctl is-active --quiet xray.service 2>/dev/null; then
    warn "Port ${INSTALL_PORT} is currently owned by the active Xray service; it will be replaced transactionally."
    return 0
  fi

  fail "TCP port ${INSTALL_PORT} is already listening. Inspect it with: ss -ltnp 'sport = :${INSTALL_PORT}'"
}

prepare_install_snapshot() {
  local snapshot
  snapshot="${BACKUP_DIR}/install-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -o root -g root -m 0700 "${snapshot}"

  backup_path "${XRAY_BIN}" xray.bin "${snapshot}"
  backup_path "${XRAY_CONFIG_FILE}" config.json "${snapshot}"
  backup_path "${XRAY_CLIENT_FILE}" client.json "${snapshot}"
  backup_path "${XRAY_UNIT}" xray.service "${snapshot}"

  if systemctl is-active --quiet xray.service 2>/dev/null; then
    : > "${snapshot}/service.active"
  fi
  if systemctl is-enabled --quiet xray.service 2>/dev/null; then
    : > "${snapshot}/service.enabled"
  fi
  printf '%s\n' "${snapshot}"
}

install_files_match() {
  local staged_xray="$1"
  local staged_config="$2"
  local staged_client="$3"
  local staged_unit="$4"

  [[ -f "${XRAY_BIN}" && -f "${XRAY_CONFIG_FILE}" && -f "${XRAY_CLIENT_FILE}" && -f "${XRAY_UNIT}" ]] || return 1
  cmp -s "${staged_xray}" "${XRAY_BIN}" || return 1
  cmp -s "${staged_config}" "${XRAY_CONFIG_FILE}" || return 1
  cmp -s "${staged_client}" "${XRAY_CLIENT_FILE}" || return 1
  cmp -s "${staged_unit}" "${XRAY_UNIT}" || return 1
  [[ "$(stat -c '%a:%U:%G' "${XRAY_BIN}")" == "755:root:root" ]] || return 1
  [[ "$(stat -c '%a:%U:%G' "${XRAY_CONFIG_FILE}")" == "640:root:xray" ]] || return 1
  [[ "$(stat -c '%a:%U:%G' "${XRAY_CLIENT_FILE}")" == "600:root:root" ]] || return 1
  [[ "$(stat -c '%a:%U:%G' "${XRAY_UNIT}")" == "644:root:root" ]] || return 1
}

wait_for_xray_health() {
  local remaining=15
  while (( remaining > 0 )); do
    if systemctl is-active --quiet xray.service && \
       ss -H -ltn "sport = :${INSTALL_PORT}" 2>/dev/null | grep -q .; then
      "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" >/dev/null
      return 0
    fi
    sleep 1
    remaining=$((remaining - 1))
  done

  systemctl status xray.service --no-pager -l >&2 || true
  journalctl -u xray.service -n 80 --no-pager >&2 || true
  return 1
}

open_firewall_port() {
  [[ "${INSTALL_OPEN_FIREWALL}" == "1" ]] || return 0

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi '^Status: active'; then
    info "Opening ${INSTALL_PORT}/tcp in UFW"
    ufw allow "${INSTALL_PORT}/tcp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    info "Opening ${INSTALL_PORT}/tcp in firewalld"
    firewall-cmd --permanent --add-port="${INSTALL_PORT}/tcp"
    firewall-cmd --reload
  fi
}

print_client_result() {
  local uri kernel_tfo
  uri="$(jq -r '.uri' "${XRAY_CLIENT_FILE}")"
  printf '\nInstallation result\n'
  printf '  Xray version : %s\n' "$("${XRAY_BIN}" version | sed -n '1p')"
  printf '  Server       : %s:%s\n' "${INSTALL_ADDRESS}" "${INSTALL_PORT}"
  printf '  SNI / target : %s / %s\n' "${INSTALL_SNI}" "${INSTALL_TARGET}"
  printf '  Fast path    : RAW + REALITY + VLESS Vision; client Mux must remain off\n'
  printf '  Xray TFO     : %s\n' "${INSTALL_TFO_MODE}"
  printf '  Client file  : %s (root-only)\n' "${XRAY_CLIENT_FILE}"
  printf '\nClient URI (credential):\n%s\n' "${uri}"

  if [[ "${INSTALL_TFO_MODE}" == "on" ]]; then
    kernel_tfo="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
    if [[ ! "${kernel_tfo}" =~ ^[0-9]+$ ]] || (( (kernel_tfo & 3) != 3 )); then
      warn "Xray TFO is on, but Linux TFO client+server bits are not both enabled. Run: sudo ./${PROGRAM_NAME} tune --enable-tfo"
    fi
  fi
}

install_command() {
  local staged_xray staged_config staged_client staged_unit snapshot
  parse_install_args "$@"
  require_root
  install_dependencies
  acquire_lock
  make_work_dir

  staged_xray="${WORK_DIR}/xray"
  staged_config="${WORK_DIR}/config.json"
  staged_client="${WORK_DIR}/client.json"
  staged_unit="${WORK_DIR}/xray.service"

  download_xray "${INSTALL_XRAY_VERSION}" "${staged_xray}"
  load_existing_install_defaults
  finalize_install_defaults
  validate_install_values
  generate_or_verify_credentials "${staged_xray}"
  detect_client_address
  validate_install_values
  preflight_reality_target

  create_xray_user_and_dirs
  check_port_conflict
  render_xray_config "${staged_config}"
  render_client_file "${staged_client}"
  render_systemd_unit "${staged_unit}"

  info "Validating the staged Xray configuration"
  "${staged_xray}" run -test -config "${staged_config}"

  if install_files_match "${staged_xray}" "${staged_config}" "${staged_client}" "${staged_unit}"; then
    info "The requested Xray state is already installed; no files changed."
    if [[ "${INSTALL_NO_START}" == "0" ]]; then
      systemctl enable --now xray.service
      wait_for_xray_health || fail "The existing Xray service did not become healthy."
    fi
    open_firewall_port
    print_client_result
    return 0
  fi

  snapshot="$(prepare_install_snapshot)"
  INSTALL_TRANSACTION="${snapshot}"

  info "Installing Xray, configuration, client material, and systemd unit atomically"
  atomic_install_file "${staged_xray}" "${XRAY_BIN}" 0755 root root
  atomic_install_file "${staged_config}" "${XRAY_CONFIG_FILE}" 0640 root xray
  atomic_install_file "${staged_client}" "${XRAY_CLIENT_FILE}" 0600 root root
  atomic_install_file "${staged_unit}" "${XRAY_UNIT}" 0644 root root
  systemctl daemon-reload

  if [[ "${INSTALL_NO_START}" == "0" ]]; then
    systemctl enable xray.service
    systemctl restart xray.service
    wait_for_xray_health || fail "Xray failed its post-install health check."
  else
    info "--no-start selected; service activation was skipped."
  fi

  write_pointer "${LAST_INSTALL_BACKUP}" "${snapshot}"
  INSTALL_TRANSACTION=""
  open_firewall_port
  print_client_result
}

softnet_counters() {
  local line field_drop field_squeeze
  local -a fields
  local drops=0
  local squeezes=0
  [[ -r /proc/net/softnet_stat ]] || {
    printf '0 0\n'
    return 0
  }

  while IFS= read -r line; do
    read -r -a fields <<<"${line}"
    field_drop="${fields[1]:-0}"
    field_squeeze="${fields[2]:-0}"
    drops=$((drops + 16#${field_drop}))
    squeezes=$((squeezes + 16#${field_squeeze}))
  done < /proc/net/softnet_stat
  printf '%s %s\n' "${drops}" "${squeezes}"
}

nstat_counter() {
  local name="$1"
  if command -v nstat >/dev/null 2>&1; then
    # Consume the complete nstat stream. Exiting awk on the first match makes
    # nstat receive SIGPIPE; with `set -o pipefail` that aborts the tune
    # transaction even though the counter was read successfully.
    nstat -az 2>/dev/null | awk -v wanted="${name}" '
      $1 == wanted && !found {value=$2; found=1}
      END {print found ? value : 0}
    '
  else
    echo 0
  fi
}

capture_qdisc_snapshot() {
  local destination="$1"
  local dev line kind relation parent token previous
  local -a fields
  : > "${destination}"

  while IFS= read -r dev; do
    [[ -n "${dev}" ]] || continue
    while IFS= read -r line; do
      read -r -a fields <<<"${line}"
      [[ "${fields[0]:-}" == "qdisc" ]] || continue
      kind="${fields[1]:-}"
      relation=""
      parent=""
      previous=""
      for token in "${fields[@]}"; do
        if [[ "${token}" == "root" ]]; then
          relation="root"
          parent="root"
          break
        fi
        if [[ "${previous}" == "parent" ]]; then
          relation="parent"
          parent="${token}"
          break
        fi
        previous="${token}"
      done
      if [[ "${relation}" == "parent" && ! "${parent}" =~ ^:[0-9]+$ ]]; then
        relation=""
      fi
      [[ -n "${relation}" ]] && printf '%s|%s|%s|%s\n' "${dev}" "${relation}" "${parent}" "${kind}" >> "${destination}"
    done < <(tc qdisc show dev "${dev}" 2>/dev/null || true)
  done < <(default_route_devs)
}

capture_sysctl_snapshot() {
  local config_file="$1"
  local destination="$2"
  local key value
  : > "${destination}"

  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    value="$(sysctl -n "${key}" 2>/dev/null || true)"
    [[ -n "${value}" ]] || continue
    printf '%s\t%s\n' "${key}" "${value}" >> "${destination}"
  done < <(awk -F= '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      print key
    }
  ' "${config_file}" | sort -u)
}

TUNE_PROFILE="balanced"
TUNE_BANDWIDTH_MBPS=""
TUNE_RTT_MS=""
TUNE_CONGESTION="bbr"
TUNE_QDISC="fq"
TUNE_HIGH_CONCURRENCY="0"
TUNE_ENABLE_TFO="0"
TUNE_LIVE_QDISC="1"

parse_tune_args() {
  while (( $# > 0 )); do
    case "$1" in
      --profile)
        need_value "$1" "$#"
        TUNE_PROFILE="$2"; shift 2
        ;;
      --bandwidth-mbps)
        need_value "$1" "$#"
        TUNE_BANDWIDTH_MBPS="$2"; shift 2
        ;;
      --rtt-ms)
        need_value "$1" "$#"
        TUNE_RTT_MS="$2"; shift 2
        ;;
      --congestion)
        need_value "$1" "$#"
        TUNE_CONGESTION="$2"; shift 2
        ;;
      --qdisc)
        need_value "$1" "$#"
        TUNE_QDISC="$2"; shift 2
        ;;
      --high-concurrency)
        TUNE_HIGH_CONCURRENCY="1"; shift
        ;;
      --enable-tfo)
        TUNE_ENABLE_TFO="1"; shift
        ;;
      --no-live-qdisc)
        TUNE_LIVE_QDISC="0"; shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        fail "Unknown tune option: $1"
        ;;
    esac
  done
}

validate_tune_values() {
  [[ "${TUNE_PROFILE}" =~ ^(balanced|throughput|latency)$ ]] || \
    fail "--profile must be balanced, throughput, or latency."
  [[ "${TUNE_CONGESTION}" =~ ^(bbr|cubic|reno)$ ]] || \
    fail "--congestion must be bbr, cubic, or reno."
  [[ "${TUNE_QDISC}" =~ ^(fq|fq_codel|cake)$ ]] || \
    fail "--qdisc must be fq, fq_codel, or cake."

  if [[ -n "${TUNE_BANDWIDTH_MBPS}" || -n "${TUNE_RTT_MS}" ]]; then
    [[ "${TUNE_BANDWIDTH_MBPS}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--bandwidth-mbps must be positive."
    [[ "${TUNE_RTT_MS}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--rtt-ms must be positive."
    awk -v b="${TUNE_BANDWIDTH_MBPS}" -v r="${TUNE_RTT_MS}" 'BEGIN {exit !(b > 0 && r > 0)}' || \
      fail "Bandwidth and RTT must both be greater than zero."
  fi
}

ensure_tuning_support() {
  if command -v modprobe >/dev/null 2>&1; then
    modprobe "sch_${TUNE_QDISC}" >/dev/null 2>&1 || true
    [[ "${TUNE_CONGESTION}" != "bbr" ]] || modprobe tcp_bbr >/dev/null 2>&1 || true
  fi

  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "${TUNE_CONGESTION}" || \
    fail "TCP congestion control '${TUNE_CONGESTION}' is unavailable on this kernel."
}

ensure_live_qdisc_is_safe() {
  local dev root_kind
  [[ "${TUNE_LIVE_QDISC}" == "1" ]] || return 0

  while IFS= read -r dev; do
    root_kind="$(tc qdisc show dev "${dev}" 2>/dev/null | awk '/ root / {print $2; exit}')"
    case "${root_kind}" in
      ""|noqueue|mq|fq|fq_codel|cake|pfifo_fast)
        ;;
      *)
        fail "${dev} uses custom root qdisc '${root_kind}'. Refusing to destroy it; use --no-live-qdisc or tune it manually."
        ;;
    esac
  done < <(default_route_devs)
}

calculate_buffer_limit() {
  local bdp multiplier floor hard_cap mem_bytes memory_cap desired
  bdp="$(awk -v bandwidth="${TUNE_BANDWIDTH_MBPS}" -v rtt="${TUNE_RTT_MS}" \
    'BEGIN {printf "%.0f", bandwidth * rtt * 125}')"

  case "${TUNE_PROFILE}" in
    latency)
      multiplier=2
      floor=$((4 * 1024 * 1024))
      hard_cap=$((32 * 1024 * 1024))
      ;;
    balanced)
      multiplier=4
      floor=$((16 * 1024 * 1024))
      hard_cap=$((128 * 1024 * 1024))
      ;;
    throughput)
      multiplier=8
      floor=$((32 * 1024 * 1024))
      hard_cap=$((256 * 1024 * 1024))
      ;;
  esac

  if [[ -r /proc/meminfo ]]; then
    mem_bytes="$(awk '/MemTotal:/ {printf "%.0f", $2 * 1024; exit}' /proc/meminfo)"
  else
    mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  fi
  [[ "${mem_bytes}" =~ ^[0-9]+$ ]] || mem_bytes=0
  memory_cap=$((mem_bytes / 16))
  (( memory_cap > 0 && memory_cap < hard_cap )) && hard_cap="${memory_cap}"
  (( floor > hard_cap )) && floor="${hard_cap}"

  desired=$((bdp * multiplier))
  (( desired < floor )) && desired="${floor}"
  (( desired > hard_cap )) && desired="${hard_cap}"
  desired=$((((desired + 4095) / 4096) * 4096))
  printf '%s\n' "${desired}"
}

render_sysctl_tuning() {
  local destination="$1"
  local listen_overflows listen_drops softnet_drops softnet_squeezes
  local buffer_limit current_backlog tuned_backlog

  read -r softnet_drops softnet_squeezes <<<"$(softnet_counters)"
  listen_overflows="$(nstat_counter TcpExtListenOverflows)"
  listen_drops="$(nstat_counter TcpExtListenDrops)"

  cat > "${destination}" <<SYSCTL
# Managed by ${PROGRAM_NAME} ${PROGRAM_VERSION}.
# Profile: ${TUNE_PROFILE}
# Only settings with a measurable role in this data path are included.

net.core.default_qdisc = ${TUNE_QDISC}
net.ipv4.tcp_congestion_control = ${TUNE_CONGESTION}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probing = 1
SYSCTL

  if [[ "${TUNE_PROFILE}" != "latency" ]]; then
    printf '%s\n' 'net.ipv4.tcp_slow_start_after_idle = 0' >> "${destination}"
  fi

  if [[ "${TUNE_ENABLE_TFO}" == "1" ]]; then
    printf '%s\n' 'net.ipv4.tcp_fastopen = 3' >> "${destination}"
  fi

  if [[ -n "${TUNE_BANDWIDTH_MBPS}" ]]; then
    buffer_limit="$(calculate_buffer_limit)"
    cat >> "${destination}" <<SYSCTL

# BDP-derived upper limits; these are maxima, not per-connection reservations.
# Inputs: ${TUNE_BANDWIDTH_MBPS} Mbps, ${TUNE_RTT_MS} ms RTT.
net.core.rmem_max = ${buffer_limit}
net.core.wmem_max = ${buffer_limit}
net.ipv4.tcp_rmem = 4096 262144 ${buffer_limit}
net.ipv4.tcp_wmem = 4096 65536 ${buffer_limit}
SYSCTL
  fi

  if [[ "${TUNE_HIGH_CONCURRENCY}" == "1" || "${listen_overflows}" -gt 0 || "${listen_drops}" -gt 0 ]]; then
    cat >> "${destination}" <<SYSCTL

# Enabled because high concurrency was requested or listen queue drops exist.
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.ip_local_port_range = 10000 65535
SYSCTL
  fi

  if [[ "${TUNE_HIGH_CONCURRENCY}" == "1" || "${softnet_drops}" -gt 0 ]]; then
    current_backlog="$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 1000)"
    [[ "${current_backlog}" =~ ^[0-9]+$ ]] || current_backlog=1000
    tuned_backlog=$((current_backlog * 2))
    (( tuned_backlog < 4096 )) && tuned_backlog=4096
    (( tuned_backlog > 65536 )) && tuned_backlog=65536
    cat >> "${destination}" <<SYSCTL

# Raised because softnet drops exist or high concurrency was requested.
net.core.netdev_max_backlog = ${tuned_backlog}
SYSCTL
  fi

  cat >> "${destination}" <<SYSCTL

# Evidence captured before applying:
# TcpExtListenOverflows=${listen_overflows}
# TcpExtListenDrops=${listen_drops}
# softnet_drops=${softnet_drops}
# softnet_time_squeeze=${softnet_squeezes}
SYSCTL
}

render_qdisc_apply_script() {
  local destination="$1"
  cat > "${destination}" <<SCRIPT
#!/bin/sh
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
QDISC='${TUNE_QDISC}'

devices="\$(ip -o route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i=="dev") print \$(i+1)}' | sort -u)"
[ -n "\${devices}" ] || devices="\$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i=="dev") {print \$(i+1); exit}}')"
[ -n "\${devices}" ]

for dev in \${devices}; do
  root_kind="\$(tc qdisc show dev "\${dev}" | awk '/ root / {print \$2; exit}')"
  if [ "\${root_kind}" = "mq" ]; then
    parents="\$(tc qdisc show dev "\${dev}" | awk '{for (i=1; i<=NF; i++) if (\$i=="parent" && \$(i+1) ~ /^:[0-9]+\$/) print \$(i+1)}' | sort -u)"
    for parent in \${parents}; do
      tc qdisc replace dev "\${dev}" parent "\${parent}" "\${QDISC}"
    done
  else
    tc qdisc replace dev "\${dev}" root "\${QDISC}"
  fi
done
SCRIPT
  chmod 0755 "${destination}"
}

render_qdisc_unit() {
  local destination="$1"
  cat > "${destination}" <<UNIT
[Unit]
Description=Apply x420 fast-path qdisc without destroying multiqueue roots
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${QDISC_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
}

prepare_tune_snapshot() {
  local staged_sysctl="$1"
  local snapshot
  snapshot="${BACKUP_DIR}/tune-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -o root -g root -m 0700 "${snapshot}"

  backup_path "${SYSCTL_FILE}" sysctl.conf "${snapshot}"
  backup_path "${QDISC_APPLY_SCRIPT}" apply-qdisc "${snapshot}"
  backup_path "${QDISC_UNIT}" qdisc.service "${snapshot}"
  capture_sysctl_snapshot "${staged_sysctl}" "${snapshot}/sysctl.before"
  capture_qdisc_snapshot "${snapshot}/qdisc.before"

  if systemctl is-active --quiet x420-fastpath-qdisc.service 2>/dev/null; then
    : > "${snapshot}/qdisc-unit.active"
  fi
  if systemctl is-enabled --quiet x420-fastpath-qdisc.service 2>/dev/null; then
    : > "${snapshot}/qdisc-unit.enabled"
  fi
  printf '%s\n' "${snapshot}"
}

warn_if_tfo_config_mismatch() {
  [[ "${TUNE_ENABLE_TFO}" == "1" ]] || return 0
  [[ -r "${XRAY_CONFIG_FILE}" ]] || return 0
  if ! jq -e '[.inbounds[]? | select(.protocol == "vless")][0].streamSettings.sockopt.tcpFastOpen == true' \
      "${XRAY_CONFIG_FILE}" >/dev/null 2>&1; then
    warn "Kernel TFO is enabled, but Xray tcpFastOpen is absent. Re-run install with --enable-tfo before benchmarking it."
  fi
}

verify_tuning() {
  local dev root_kind
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "${TUNE_CONGESTION}" ]] || \
    fail "Congestion-control verification failed."

  [[ "${TUNE_LIVE_QDISC}" == "1" ]] || return 0
  while IFS= read -r dev; do
    root_kind="$(tc qdisc show dev "${dev}" | awk '/ root / {print $2; exit}')"
    if [[ "${root_kind}" == "mq" ]]; then
      tc qdisc show dev "${dev}" | grep -q "qdisc ${TUNE_QDISC} .* parent" || \
        fail "No ${TUNE_QDISC} leaf qdisc found on multiqueue device ${dev}."
    else
      [[ "${root_kind}" == "${TUNE_QDISC}" ]] || fail "qdisc verification failed on ${dev}."
    fi
  done < <(default_route_devs)
}

tune_command() {
  local staged_sysctl staged_apply staged_unit snapshot
  parse_tune_args "$@"
  validate_tune_values
  require_root
  require_linux
  require_systemd
  install_dependencies
  acquire_lock
  make_work_dir
  ensure_tuning_support
  ensure_live_qdisc_is_safe

  staged_sysctl="${WORK_DIR}/sysctl.conf"
  staged_apply="${WORK_DIR}/apply-qdisc"
  staged_unit="${WORK_DIR}/qdisc.service"
  render_sysctl_tuning "${staged_sysctl}"
  render_qdisc_apply_script "${staged_apply}"
  render_qdisc_unit "${staged_unit}"
  warn_if_tfo_config_mismatch

  snapshot="$(prepare_tune_snapshot "${staged_sysctl}")"
  TUNE_TRANSACTION="${snapshot}"

  info "Applying the measured ${TUNE_PROFILE} kernel profile"
  install -d -o root -g root -m 0755 "$(dirname "${QDISC_APPLY_SCRIPT}")"
  atomic_install_file "${staged_sysctl}" "${SYSCTL_FILE}" 0644 root root
  atomic_install_file "${staged_apply}" "${QDISC_APPLY_SCRIPT}" 0755 root root
  atomic_install_file "${staged_unit}" "${QDISC_UNIT}" 0644 root root
  sysctl -p "${SYSCTL_FILE}"
  systemctl daemon-reload
  systemctl enable x420-fastpath-qdisc.service
  if [[ "${TUNE_LIVE_QDISC}" == "1" ]]; then
    systemctl restart x420-fastpath-qdisc.service
  else
    info "--no-live-qdisc selected; qdisc will be applied on the next service start or boot."
  fi

  verify_tuning
  write_pointer "${LAST_TUNE_BACKUP}" "${snapshot}"
  TUNE_TRANSACTION=""

  printf '\nTuning result\n'
  printf '  Profile      : %s\n' "${TUNE_PROFILE}"
  printf '  Congestion   : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control)"
  printf '  Default qdisc: %s\n' "$(sysctl -n net.core.default_qdisc)"
  [[ -z "${TUNE_BANDWIDTH_MBPS}" ]] || \
    printf '  Buffer model : %s Mbps x %s ms RTT\n' "${TUNE_BANDWIDTH_MBPS}" "${TUNE_RTT_MS}"
  printf '  Rollback     : sudo ./%s rollback tune\n' "${PROGRAM_NAME}"
}

print_section() {
  printf '\n[%s]\n' "$1"
}

read_file_or_unknown() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    sed -n '1p' "${path}"
  else
    printf 'unknown'
  fi
}

probe_fast_path() {
  if [[ ! -r "${XRAY_CONFIG_FILE}" ]]; then
    printf 'Xray config: unavailable or not readable\n'
    return 0
  fi

  if command -v jq >/dev/null 2>&1 && jq -e '
      (.inbounds // []) | any(
        .protocol == "vless"
        and ((.streamSettings.network // "tcp") == "raw" or (.streamSettings.network // "tcp") == "tcp")
        and .streamSettings.security == "reality"
        and any(.settings.clients[]?; .flow == "xtls-rprx-vision")
      )
    ' "${XRAY_CONFIG_FILE}" >/dev/null 2>&1; then
    printf 'Server fast-path eligibility: YES (RAW/TCP + REALITY + Vision)\n'
    printf 'Runtime splice/direct-copy: payload-dependent; inner TLS 1.3 and client Mux=off are still required\n'
  else
    printf 'Server fast-path eligibility: NO or could not be verified\n'
  fi
}

probe_interface() {
  local dev="$1"
  local mtu rx_queues tx_queues stat value
  mtu="$(cat "/sys/class/net/${dev}/mtu" 2>/dev/null || echo unknown)"
  rx_queues="$(find "/sys/class/net/${dev}/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l | tr -d ' ')"
  tx_queues="$(find "/sys/class/net/${dev}/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l | tr -d ' ')"

  printf 'Interface: %s  MTU=%s  RX queues=%s  TX queues=%s\n' "${dev}" "${mtu}" "${rx_queues}" "${tx_queues}"
  tc qdisc show dev "${dev}" 2>/dev/null | sed 's/^/  /' || true

  for stat in rx_dropped tx_dropped rx_errors tx_errors; do
    value="$(cat "/sys/class/net/${dev}/statistics/${stat}" 2>/dev/null || echo unknown)"
    printf '  %-12s %s\n' "${stat}:" "${value}"
  done

  if command -v ethtool >/dev/null 2>&1; then
    ethtool -k "${dev}" 2>/dev/null | \
      awk '/^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|receive-hashing):/ {print "  " $0}' || true
  fi
}

probe_command() {
  local devs dev softnet_drops softnet_squeezes
  require_linux

  print_section system
  printf 'Kernel       : %s\n' "$(uname -srmo)"
  printf 'Architecture : %s\n' "$(uname -m)"
  printf 'vCPU         : %s\n' "$(nproc 2>/dev/null || echo unknown)"
  printf 'CPU model    : %s\n' "$(awk -F: '/model name|Hardware/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
  printf 'Memory       : %s kB\n' "$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    printf 'Virtualization: %s\n' "$(systemd-detect-virt 2>/dev/null || echo none)"
  fi

  print_section xray
  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" version 2>/dev/null | sed -n '1p'
  else
    printf 'Xray binary: not installed\n'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    printf 'Service active : %s\n' "$(systemctl is-active xray.service 2>/dev/null || true)"
    printf 'Service enabled: %s\n' "$(systemctl is-enabled xray.service 2>/dev/null || true)"
  fi
  probe_fast_path

  print_section tcp
  for key in \
    net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_available_congestion_control \
    net.core.default_qdisc \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog \
    net.core.netdev_max_backlog \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem; do
    printf '%-43s %s\n' "${key}:" "$(sysctl -n "${key}" 2>/dev/null || echo unavailable)"
  done
  printf '%-43s %s\n' 'TcpExtListenOverflows:' "$(nstat_counter TcpExtListenOverflows)"
  printf '%-43s %s\n' 'TcpExtListenDrops:' "$(nstat_counter TcpExtListenDrops)"
  printf '%-43s %s\n' 'TcpRetransSegs:' "$(nstat_counter TcpRetransSegs)"
  read -r softnet_drops softnet_squeezes <<<"$(softnet_counters)"
  printf '%-43s %s\n' 'softnet drops:' "${softnet_drops}"
  printf '%-43s %s\n' 'softnet time_squeeze:' "${softnet_squeezes}"

  print_section interfaces
  devs="$(default_route_devs 2>/dev/null || true)"
  if [[ -z "${devs}" ]]; then
    printf 'No default-route interface detected.\n'
  else
    while IFS= read -r dev; do
      probe_interface "${dev}"
    done <<<"${devs}"
  fi

  print_section sockets
  ss -s 2>/dev/null || true

  print_section interpretation
  if (( softnet_drops > 0 )); then
    printf 'softnet drops are non-zero: inspect CPU/IRQ/RSS before growing queues further.\n'
  else
    printf 'No accumulated softnet drops: a very large netdev backlog is not justified by this snapshot.\n'
  fi
  if (( $(nstat_counter TcpExtListenOverflows) > 0 )); then
    printf 'Listen overflows exist: accept/SYN queues or connection handling deserve attention.\n'
  else
    printf 'No accumulated listen overflow: huge accept queues are not currently evidence-backed.\n'
  fi
  printf 'Counters are cumulative since boot; compare deltas during a controlled benchmark.\n'
}

status_command() {
  local show_client="0"
  while (( $# > 0 )); do
    case "$1" in
      --show-client) show_client="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown status option: $1" ;;
    esac
  done

  require_linux
  print_section service
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status xray.service --no-pager -l 2>/dev/null | sed -n '1,14p' || true
  fi

  print_section configuration
  probe_fast_path
  if (( EUID == 0 )) && [[ -x "${XRAY_BIN}" && -r "${XRAY_CONFIG_FILE}" ]]; then
    if "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" >/dev/null 2>&1; then
      printf 'Configuration test: PASS\n'
    else
      printf 'Configuration test: FAIL\n'
    fi
  else
    printf 'Configuration test: skipped (root/read access required)\n'
  fi

  print_section tuning
  printf 'Congestion: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)"
  printf 'Default qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)"
  [[ -f "${SYSCTL_FILE}" ]] && printf 'Managed sysctl: %s\n' "${SYSCTL_FILE}" || printf 'Managed sysctl: not installed\n'

  if [[ "${show_client}" == "1" ]]; then
    print_section client
    (( EUID == 0 )) || fail "--show-client requires root because it reveals the UUID credential."
    [[ -r "${XRAY_CLIENT_FILE}" ]] || fail "Client file is missing."
    warn "The following URI is an authentication credential."
    jq -r '.uri' "${XRAY_CLIENT_FILE}"
  fi
}

validated_snapshot_pointer() {
  local type="$1"
  local pointer snapshot pattern
  case "${type}" in
    install)
      pointer="${LAST_INSTALL_BACKUP}"
      pattern="${BACKUP_DIR}/install-"
      ;;
    tune)
      pointer="${LAST_TUNE_BACKUP}"
      pattern="${BACKUP_DIR}/tune-"
      ;;
    *)
      return 1
      ;;
  esac

  snapshot="$(read_pointer "${pointer}" || true)"
  [[ -n "${snapshot}" && -d "${snapshot}" && "${snapshot}" == "${pattern}"* ]] || \
    fail "No valid ${type} rollback snapshot is available."
  printf '%s\n' "${snapshot}"
}

rollback_command() {
  local target="${1:-}"
  local snapshot
  [[ $# -eq 1 ]] || fail "Usage: ${PROGRAM_NAME} rollback install|tune|all"
  [[ "${target}" =~ ^(install|tune|all)$ ]] || fail "Rollback target must be install, tune, or all."

  require_root
  require_linux
  require_systemd
  acquire_lock

  if [[ "${target}" == "tune" || "${target}" == "all" ]]; then
    snapshot="$(validated_snapshot_pointer tune)"
    restore_tune_backup "${snapshot}"
  fi

  if [[ "${target}" == "install" || "${target}" == "all" ]]; then
    snapshot="$(validated_snapshot_pointer install)"
    restore_install_backup "${snapshot}"
  fi

  info "Rollback completed: ${target}"
}

process_cpu_ticks() {
  local pid="$1"
  [[ -r "/proc/${pid}/stat" ]] || return 1
  awk '{print $14 + $15}' "/proc/${pid}/stat"
}

interface_stat() {
  local dev="$1"
  local stat="$2"
  cat "/sys/class/net/${dev}/statistics/${stat}"
}

benchmark_server_command() {
  local duration=15
  local dev=""
  local pid ticks_per_second
  local rx_before tx_before rx_after tx_after
  local cpu_before cpu_after retrans_before retrans_after
  local rx_delta tx_delta cpu_ticks_delta retrans_delta

  while (( $# > 0 )); do
    case "$1" in
      --duration)
        need_value "$1" "$#"
        duration="$2"; shift 2
        ;;
      --interface)
        need_value "$1" "$#"
        dev="$2"; shift 2
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        fail "Unknown benchmark server option: $1"
        ;;
    esac
  done

  require_linux
  require_systemd
  [[ "${duration}" =~ ^[0-9]+$ ]] || fail "--duration must be an integer."
  duration=$((10#${duration}))
  (( duration >= 5 && duration <= 60 )) || fail "--duration must be between 5 and 60 seconds."
  [[ -z "${dev}" || "${dev}" =~ ^[A-Za-z0-9_.:@-]+$ ]] || fail "--interface is malformed."

  if [[ -z "${dev}" ]]; then
    dev="$(default_route_devs | sed -n '1p')"
  fi
  [[ -d "/sys/class/net/${dev}" ]] || fail "Network interface not found: ${dev}"

  pid="$(systemctl show -p MainPID --value xray.service 2>/dev/null || true)"
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" ]] || fail "Xray is not running."
  ticks_per_second="$(getconf CLK_TCK)"

  rx_before="$(interface_stat "${dev}" rx_bytes)"
  tx_before="$(interface_stat "${dev}" tx_bytes)"
  cpu_before="$(process_cpu_ticks "${pid}")"
  retrans_before="$(nstat_counter TcpRetransSegs)"

  info "Sampling ${dev} and Xray PID ${pid} for ${duration}s; generate representative client traffic now"
  sleep "${duration}"

  [[ -r "/proc/${pid}/stat" ]] || fail "Xray exited or restarted during the benchmark."
  rx_after="$(interface_stat "${dev}" rx_bytes)"
  tx_after="$(interface_stat "${dev}" tx_bytes)"
  cpu_after="$(process_cpu_ticks "${pid}")"
  retrans_after="$(nstat_counter TcpRetransSegs)"

  rx_delta=$((rx_after - rx_before))
  tx_delta=$((tx_after - tx_before))
  cpu_ticks_delta=$((cpu_after - cpu_before))
  retrans_delta=$((retrans_after - retrans_before))
  (( rx_delta >= 0 && tx_delta >= 0 && cpu_ticks_delta >= 0 )) || fail "A sampled counter moved backwards."

  printf '\nServer benchmark (%ss, interface %s)\n' "${duration}" "${dev}"
  awk -v rx="${rx_delta}" -v tx="${tx_delta}" -v seconds="${duration}" \
      -v cpu_ticks="${cpu_ticks_delta}" -v hz="${ticks_per_second}" '
    BEGIN {
      rx_mbps = rx * 8 / seconds / 1000000
      tx_mbps = tx * 8 / seconds / 1000000
      wire_mbps = (rx + tx) * 8 / seconds / 1000000
      cpu_seconds = cpu_ticks / hz
      cpu_percent = cpu_seconds / seconds * 100
      gib = (rx + tx) / 1073741824
      printf "  RX wire rate     : %.2f Mbps\n", rx_mbps
      printf "  TX wire rate     : %.2f Mbps\n", tx_mbps
      printf "  Aggregate wire   : %.2f Mbps\n", wire_mbps
      printf "  Xray CPU         : %.2f CPU-seconds (%.1f%% of one core)\n", cpu_seconds, cpu_percent
      if (gib > 0) printf "  CPU efficiency   : %.3f CPU-seconds/GiB of aggregate wire bytes\n", cpu_seconds / gib
      else print "  CPU efficiency   : insufficient traffic"
    }
  '
  printf '  TCP retrans delta: %s\n' "${retrans_delta}"
  printf '\nAggregate wire counts both proxy-facing legs and is not application goodput.\n'
  printf 'Pair this sample with the client benchmark and compare deltas across identical loads.\n'
}

CLIENT_BENCH_URL=""
CLIENT_BENCH_PROXY=""
CLIENT_BENCH_ROUNDS="5"
CLIENT_BENCH_MAX_TIME="60"
CLIENT_BENCH_OUTPUT=""

parse_benchmark_client_args() {
  while (( $# > 0 )); do
    case "$1" in
      --url)
        need_value "$1" "$#"
        CLIENT_BENCH_URL="$2"; shift 2
        ;;
      --proxy)
        need_value "$1" "$#"
        CLIENT_BENCH_PROXY="$2"; shift 2
        ;;
      --rounds)
        need_value "$1" "$#"
        CLIENT_BENCH_ROUNDS="$2"; shift 2
        ;;
      --max-time)
        need_value "$1" "$#"
        CLIENT_BENCH_MAX_TIME="$2"; shift 2
        ;;
      --output)
        need_value "$1" "$#"
        CLIENT_BENCH_OUTPUT="$2"; shift 2
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        fail "Unknown benchmark client option: $1"
        ;;
    esac
  done

  [[ "${CLIENT_BENCH_URL}" =~ ^https?:// ]] || fail "--url must be an HTTP(S) URL."
  [[ "${CLIENT_BENCH_PROXY}" =~ ^(socks5h?|https?):// ]] || \
    fail "--proxy must be a SOCKS or HTTP proxy URL."
  [[ "${CLIENT_BENCH_ROUNDS}" =~ ^[0-9]+$ ]] || fail "--rounds must be an integer."
  CLIENT_BENCH_ROUNDS=$((10#${CLIENT_BENCH_ROUNDS}))
  (( CLIENT_BENCH_ROUNDS >= 1 && CLIENT_BENCH_ROUNDS <= 20 )) || fail "--rounds must be between 1 and 20."
  [[ "${CLIENT_BENCH_MAX_TIME}" =~ ^[0-9]+$ ]] || fail "--max-time must be an integer."
  CLIENT_BENCH_MAX_TIME=$((10#${CLIENT_BENCH_MAX_TIME}))
  (( CLIENT_BENCH_MAX_TIME >= 5 && CLIENT_BENCH_MAX_TIME <= 600 )) || \
    fail "--max-time must be between 5 and 600 seconds."
  if [[ -n "${CLIENT_BENCH_OUTPUT}" && -e "${CLIENT_BENCH_OUTPUT}" ]]; then
    fail "Refusing to overwrite benchmark output: ${CLIENT_BENCH_OUTPUT}"
  fi
}

run_client_curl() {
  local mode="$1"
  local round="$2"
  local csv_file="$3"
  local result
  local -a proxy_args

  if [[ "${mode}" == "proxy" ]]; then
    proxy_args=(--proxy "${CLIENT_BENCH_PROXY}")
  else
    proxy_args=(--noproxy '*')
  fi

  info "Client benchmark ${mode}, round ${round}/${CLIENT_BENCH_ROUNDS}"
  if ! result="$(curl --fail --location --silent --show-error \
      --output /dev/null --max-time "${CLIENT_BENCH_MAX_TIME}" \
      "${proxy_args[@]}" \
      --write-out '%{http_code},%{speed_download},%{time_connect},%{time_starttransfer},%{time_total},%{size_download}' \
      "${CLIENT_BENCH_URL}")"; then
    fail "curl failed during ${mode} round ${round}."
  fi

  printf '%s,%s,%s\n' "${mode}" "${round}" "${result}" >> "${csv_file}"
}

csv_mode_average() {
  local csv_file="$1"
  local mode="$2"
  local column="$3"
  awk -F, -v wanted="${mode}" -v column="${column}" '
    NR > 1 && $1 == wanted {sum += $column; count++}
    END {if (count) printf "%.9f", sum/count; else print 0}
  ' "${csv_file}"
}

csv_mode_percentile() {
  local csv_file="$1"
  local mode="$2"
  local column="$3"
  local percentile="$4"
  awk -F, -v wanted="${mode}" -v column="${column}" 'NR > 1 && $1 == wanted {print $column}' "${csv_file}" | \
    sort -n | awk -v p="${percentile}" '
      {values[NR]=$1}
      END {
        if (NR == 0) {print 0; exit}
        idx=int((NR*p + 99)/100)
        if (idx < 1) idx=1
        if (idx > NR) idx=NR
        printf "%.6f", values[idx]
      }
    '
}

print_client_benchmark_summary() {
  local csv_file="$1"
  local mode avg_speed avg_mbps avg_ttfb avg_total p95_total
  local direct_speed proxy_speed

  printf '\nClient benchmark summary\n'
  for mode in direct proxy; do
    avg_speed="$(csv_mode_average "${csv_file}" "${mode}" 4)"
    avg_ttfb="$(csv_mode_average "${csv_file}" "${mode}" 6)"
    avg_total="$(csv_mode_average "${csv_file}" "${mode}" 7)"
    p95_total="$(csv_mode_percentile "${csv_file}" "${mode}" 7 95)"
    avg_mbps="$(awk -v bytes="${avg_speed}" 'BEGIN {printf "%.2f", bytes*8/1000000}')"
    printf '  %-6s avg=%9s Mbps  avg-TTFB=%7.3fs  avg-total=%7.3fs  p95-total=%7.3fs\n' \
      "${mode}" "${avg_mbps}" "${avg_ttfb}" "${avg_total}" "${p95_total}"
  done

  direct_speed="$(csv_mode_average "${csv_file}" direct 4)"
  proxy_speed="$(csv_mode_average "${csv_file}" proxy 4)"
  awk -v direct="${direct_speed}" -v proxy="${proxy_speed}" '
    BEGIN {
      if (direct > 0) printf "  Proxy/direct download ratio: %.1f%%\n", proxy/direct*100
      else print "  Proxy/direct download ratio: unavailable"
    }
  '
  printf '\nThe ratio includes route differences; use the same URL, client, time window, and server load for A/B decisions.\n'
}

benchmark_client_command() {
  local csv_file round first second
  parse_benchmark_client_args "$@"
  command -v curl >/dev/null 2>&1 || fail "curl is required."
  make_work_dir
  csv_file="${WORK_DIR}/client-benchmark.csv"
  printf '%s\n' 'mode,round,http_code,speed_download_Bps,time_connect_s,time_starttransfer_s,time_total_s,size_download_B' > "${csv_file}"

  for ((round=1; round<=CLIENT_BENCH_ROUNDS; round++)); do
    if (( round % 2 == 1 )); then
      first=direct; second=proxy
    else
      first=proxy; second=direct
    fi
    run_client_curl "${first}" "${round}" "${csv_file}"
    run_client_curl "${second}" "${round}" "${csv_file}"
  done

  print_client_benchmark_summary "${csv_file}"
  if [[ -n "${CLIENT_BENCH_OUTPUT}" ]]; then
    install -m 0644 "${csv_file}" "${CLIENT_BENCH_OUTPUT}"
    printf 'CSV saved to: %s\n' "${CLIENT_BENCH_OUTPUT}"
  fi
}

benchmark_command() {
  local mode="${1:-}"
  (( $# > 0 )) || fail "Usage: ${PROGRAM_NAME} benchmark server|client [options]"
  shift
  case "${mode}" in
    server) benchmark_server_command "$@" ;;
    client) benchmark_client_command "$@" ;;
    *) fail "Benchmark mode must be server or client." ;;
  esac
}

main() {
  local command="${1:-help}"
  if (( $# > 0 )); then
    shift
  fi

  case "${command}" in
    install) install_command "$@" ;;
    probe) (( $# == 0 )) || fail "probe takes no options"; probe_command ;;
    tune) tune_command "$@" ;;
    benchmark) benchmark_command "$@" ;;
    status) status_command "$@" ;;
    rollback) rollback_command "$@" ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s %s\n' "${PROGRAM_NAME}" "${PROGRAM_VERSION}" ;;
    *) fail "Unknown command: ${command}. Run ${PROGRAM_NAME} help." ;;
  esac
}

main "$@"
