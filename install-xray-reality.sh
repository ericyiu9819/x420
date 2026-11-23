#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly STATE_FILE="${CONFIG_DIR}/reality-install.env"
readonly CLIENT_FILE="/root/xray-reality-client.txt"

PORT=443
TARGET_DOMAIN="www.tesla.com"
SERVER_NAME="www.tesla.com"
PUBLIC_IP=""
CUSTOM_UUID=""
CUSTOM_SHORT_ID=""
REGENERATE=0
SKIP_FIREWALL=0
SKIP_TARGET_CHECK=0
ENABLE_BBR=0

log() {
  printf '[%s] %s\n' "$1" "$2"
}

die() {
  log ERROR "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
安装 VLESS + TCP + REALITY + XTLS Vision 服务端。

用法：
  sudo bash install-xray-reality.sh [选项]

选项：
  --port PORT             监听端口，默认 443
  --target DOMAIN         REALITY target，默认 www.tesla.com
  --server-name DOMAIN    REALITY SNI，默认与 target 相同
  --public-ip IP          用于生成客户端链接；默认自动探测公网 IPv4
  --uuid UUID             使用指定 UUID；默认自动生成
  --short-id HEX          2-16 个偶数长度十六进制字符；默认自动生成
  --regenerate            已运行过时重新生成 UUID 和 REALITY 密钥
  --skip-firewall         不自动放行监听端口
  --skip-target-check     跳过 REALITY 目标 TLS 检查
  --enable-bbr            写入 sysctl 配置并尝试启用 BBR
  -h, --help              显示帮助

示例：
  sudo bash install-xray-reality.sh
  sudo bash install-xray-reality.sh --public-ip 203.0.113.10
  sudo bash install-xray-reality.sh --target www.tesla.com --server-name www.tesla.com
EOF
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "选项 $1 缺少参数"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --port)
        require_value "$@"
        PORT="$2"
        shift 2
        ;;
      --target)
        require_value "$@"
        TARGET_DOMAIN="$2"
        SERVER_NAME="$2"
        shift 2
        ;;
      --server-name)
        require_value "$@"
        SERVER_NAME="$2"
        shift 2
        ;;
      --public-ip)
        require_value "$@"
        PUBLIC_IP="$2"
        shift 2
        ;;
      --uuid)
        require_value "$@"
        CUSTOM_UUID="$2"
        shift 2
        ;;
      --short-id)
        require_value "$@"
        CUSTOM_SHORT_ID="${2,,}"
        shift 2
        ;;
      --regenerate)
        REGENERATE=1
        shift
        ;;
      --skip-firewall)
        SKIP_FIREWALL=1
        shift
        ;;
      --skip-target-check)
        SKIP_TARGET_CHECK=1
        shift
        ;;
      --enable-bbr)
        ENABLE_BBR=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知选项：$1"
        ;;
    esac
  done
}

validate_inputs() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字"
  ((PORT >= 1 && PORT <= 65535)) || die "端口范围必须为 1-65535"

  local domain_re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
  [[ "$TARGET_DOMAIN" =~ $domain_re ]] || die "无效的 target 域名：$TARGET_DOMAIN"
  [[ "$SERVER_NAME" =~ $domain_re ]] || die "无效的 server-name：$SERVER_NAME"

  if [[ -n "$CUSTOM_UUID" ]]; then
    [[ "$CUSTOM_UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
      || die "无效的 UUID"
  fi

  if [[ -n "$CUSTOM_SHORT_ID" ]]; then
    [[ "$CUSTOM_SHORT_ID" =~ ^[0-9a-f]{2,16}$ ]] || die "Short ID 必须为 2-16 个十六进制字符"
    (( ${#CUSTOM_SHORT_ID} % 2 == 0 )) || die "Short ID 的字符数必须为偶数"
  fi
}

check_environment() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 或 sudo 运行"
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux"
  command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd"
  [[ -d /run/systemd/system ]] || die "systemd 未运行"

  if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
    if ! systemctl is-active --quiet xray 2>/dev/null; then
      die "TCP $PORT 已被其他程序占用"
    fi
    log INFO "TCP $PORT 当前由已安装的 Xray 使用，将更新现有配置"
  fi
}

install_dependencies() {
  log INFO "安装基础依赖"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl openssl unzip iproute2 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl openssl unzip iproute >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl openssl unzip iproute >/dev/null
  else
    die "仅自动支持 apt、dnf 或 yum 系统"
  fi
}

install_xray() {
  local tmp_dir installer
  tmp_dir="$(mktemp -d)"
  installer="${tmp_dir}/install-release.sh"
  trap 'rm -rf -- "${tmp_dir:-}"' RETURN

  log INFO "下载并运行 XTLS 官方安装器"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$INSTALLER_URL" --output "$installer"
  chmod 0700 "$installer"
  bash "$installer" install
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装失败"
  log INFO "$($XRAY_BIN version | head -n 1)"

  rm -rf -- "$tmp_dir"
  trap - RETURN
}

state_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE"
}

generate_credentials() {
  UUID=""
  PRIVATE_KEY=""
  PUBLIC_KEY=""
  SHORT_ID=""

  if [[ -f "$STATE_FILE" && "$REGENERATE" -eq 0 && -z "$CUSTOM_UUID" && -z "$CUSTOM_SHORT_ID" ]]; then
    UUID="$(state_value UUID)"
    PRIVATE_KEY="$(state_value PRIVATE_KEY)"
    PUBLIC_KEY="$(state_value PUBLIC_KEY)"
    SHORT_ID="$(state_value SHORT_ID)"
    if [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]]; then
      log INFO "沿用上次生成的 UUID、REALITY 密钥和 Short ID"
      return
    fi
    log WARN "状态文件不完整，将重新生成凭据"
  fi

  UUID="${CUSTOM_UUID:-$($XRAY_BIN uuid)}"
  SHORT_ID="${CUSTOM_SHORT_ID:-$(openssl rand -hex 8)}"

  local key_output
  key_output="$($XRAY_BIN x25519)"
  PRIVATE_KEY="$(awk -F': *' 'tolower($1) ~ /^private/ {print $2; exit}' <<<"$key_output")"
  PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /^(public|password)/ {print $2; exit}' <<<"$key_output")"

  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || {
    printf '%s\n' "$key_output" >&2
    die "无法解析 xray x25519 输出"
  }
}

check_target() {
  ((SKIP_TARGET_CHECK == 1)) && return
  log INFO "检查 REALITY 目标 ${TARGET_DOMAIN}:443"
  if ! timeout 20 "$XRAY_BIN" tls ping "${TARGET_DOMAIN}:443" >/dev/null 2>&1; then
    die "${TARGET_DOMAIN}:443 未通过 Xray TLS 检查；检查网络后重试，或使用 --skip-target-check"
  fi
}

backup_existing_config() {
  [[ -s "$CONFIG_FILE" ]] || return
  local backup
  backup="${CONFIG_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a -- "$CONFIG_FILE" "$backup"
  log INFO "旧配置已备份到 $backup"
}

write_config() {
  local tmp_config config_group
  mkdir -p "$CONFIG_DIR"
  # Xray determines the config format from the final filename extension.
  tmp_config="$(mktemp "${CONFIG_DIR}/config.XXXXXX.json")"

  cat >"$tmp_config" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${TARGET_DOMAIN}:443",
          "xver": 0,
          "serverNames": [
            "${SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp",
        "port": "25,465,587",
        "outboundTag": "block"
      }
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300
      }
    }
  }
}
EOF

  "$XRAY_BIN" run -test -config "$tmp_config" >/dev/null \
    || die "生成的 Xray 配置未通过检查"

  config_group="root"
  getent group xray >/dev/null 2>&1 && config_group="xray"
  install -o root -g "$config_group" -m 0640 "$tmp_config" "$CONFIG_FILE"
  rm -f -- "$tmp_config"

  cat >"$STATE_FILE" <<EOF
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EOF
  chmod 0600 "$STATE_FILE"
}

configure_firewall() {
  ((SKIP_FIREWALL == 1)) && return

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null
    log INFO "已通过 UFW 放行 TCP $PORT"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    log INFO "已通过 firewalld 放行 TCP $PORT"
  else
    log WARN "未发现已启用的 UFW/firewalld；请确认云安全组和系统防火墙已放行 TCP $PORT"
  fi
}

enable_bbr() {
  ((ENABLE_BBR == 1)) || return
  local sysctl_file="/etc/sysctl.d/99-xray-bbr.conf"
  modprobe tcp_bbr 2>/dev/null || true
  cat >"$sysctl_file" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  if sysctl --system >/dev/null && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
    log INFO "BBR 已启用"
  else
    log WARN "当前内核未能启用 BBR；已保留 $sysctl_file"
  fi
}

detect_public_ip() {
  [[ -n "$PUBLIC_IP" ]] && return
  PUBLIC_IP="$(curl -4 --fail --silent --show-error --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    PUBLIC_IP=""
  fi
}

write_client_info() {
  detect_public_ip
  local endpoint uri_host node_name uri
  endpoint="${PUBLIC_IP:-请填写VPS公网IP}"
  uri_host="$endpoint"
  [[ "$uri_host" == *:* ]] && uri_host="[${uri_host}]"
  node_name="$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9._-' | cut -c1-32)"
  node_name="${node_name:-Tesla-Reality}"

  uri="vless://${UUID}@${uri_host}:${PORT}?encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${node_name}"

  cat >"$CLIENT_FILE" <<EOF
VLESS URI:
${uri}

客户端参数：
地址: ${endpoint}
端口: ${PORT}
UUID: ${UUID}
Flow: xtls-rprx-vision
