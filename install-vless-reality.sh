#!/usr/bin/env bash
# Run on a Debian or Ubuntu VPS with systemd and a public IPv4 address.
set -euo pipefail
umask 077

server_name=www.tesla.com
port=443
xray=/usr/local/bin/xray
config_dir=/usr/local/etc/xray
config_file="$config_dir/config.json"
link_file=/root/vless-reality.txt
installer_url=https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

enable_bbr_fq() {
  local settings="$work_dir/bbr-fq.conf"
  local previous_qdisc previous_cc interface qdiscs scope parent
  local -a attachment

  previous_qdisc=$(sysctl -n net.core.default_qdisc) || return 1
  previous_cc=$(sysctl -n net.ipv4.tcp_congestion_control) || return 1
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  printf '%s\n' 'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr' > "$settings" || return 1
  if ! sysctl -q -p "$settings" ||
     ! install -m 0644 "$settings" /etc/sysctl.d/99-xray-bbr-fq.conf; then
    sysctl -qw "net.core.default_qdisc=$previous_qdisc" \
      "net.ipv4.tcp_congestion_control=$previous_cc" || true
    return 1
  fi
  printf '已启用 BBR，默认队列设为 FQ，重启后自动加载。\n'

  # A new default qdisc does not replace queues already attached to an interface.
  interface=$(ip -o -4 route show default | awk '
    !dev {for (i = 1; i < NF; i++) if ($i == "dev") {dev = $(i+1); break}}
    END {if (dev) print dev}
  ') || return 1
  [[ -n $interface ]] || return 1
  qdiscs=$(tc qdisc show dev "$interface") || return 1

  # Only replace implicit defaults. Keep an mq root and manage its leaves.
  while read -r scope parent; do
    attachment=("$scope")
    if [[ $scope == parent ]]; then
      attachment+=("$parent")
    fi
    tc qdisc replace dev "$interface" "${attachment[@]}" fq || return 1
  done < <(awk '
    $2 ~ /^(fq_codel|pfifo_fast|noqueue)$/ && $3 == "0:" {
      if ($4 == "root") print "root"
      if ($4 == "parent") leaves[++count] = $5
    }
    $4 == "root" {multiqueue = ($2 == "mq")}
    END {if (multiqueue) for (i = 1; i <= count; i++) print "parent", leaves[i]}
  ' <<< "$qdiscs")

  if tc qdisc show dev "$interface" | awk '
    $4 == "root" {root = $2}
    $4 == "parent" {leaves++; if ($2 != "fq") other++}
    END {exit !(root == "fq" || (root == "mq" && leaves && !other))}
  '; then
    printf '出口网卡 %s 已启用 FQ。\n' "$interface"
  else
    printf '提示：出口网卡 %s 仍有其他队列规则，请用 tc qdisc show 检查。\n' "$interface" >&2
    return 1
  fi
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '用法：sudo bash %s VPS公网IPv4\n' "$0"
  exit 0
fi

[[ $# -eq 1 ]] || die "用法：sudo bash $0 VPS公网IPv4"
public_ip=$1
if [[ ! $public_ip =~ ^([1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
  die "请输入 VPS 控制台显示的公网 IPv4 地址。"
fi
for octet in "${BASH_REMATCH[@]:1}"; do
  (( octet <= 255 )) || die "IPv4 地址中的数字不能超过 255。"
done

(( EUID == 0 )) || die "请在 VPS 上用 sudo 运行此脚本。"
[[ -d /run/systemd/system ]] && command -v apt-get >/dev/null ||
  die "此脚本适用于运行 systemd 的 Debian 或 Ubuntu。"

exec 9>/run/lock/vless-reality-install.lock
flock -n 9 || die "已有另一个安装进程在运行。"

[[ ! -e $link_file ]] || die "节点链接已保存在 $link_file，可用 sudo cat $link_file 查看。"
if [[ -e $config_file && $(tr -d '[:space:]' < "$config_file") != '{}' ]]; then
  die "检测到现有 Xray 配置 $config_file。此脚本适用于新节点。"
fi

if ! command -v curl >/dev/null || ! command -v ss >/dev/null ||
   ! command -v ip >/dev/null || ! command -v tc >/dev/null ||
   ! command -v sysctl >/dev/null || ! command -v modprobe >/dev/null ||
   ! command -v openssl >/dev/null || ! command -v unzip >/dev/null; then
  apt-get update
  apt-get install -y ca-certificates curl iproute2 kmod openssl procps unzip
fi

[[ -z $(ss -H -ltn "sport = :$port") ]] || die "TCP $port 已被占用。"

printf '正在检查 VPS 到 %s 的 TLS 1.3 和 HTTP/2 连接…\n' "$server_name"
http_version=$(curl --noproxy '*' --silent --show-error --http2 --tlsv1.3 \
  --connect-timeout 8 --max-time 20 --output /dev/null --write-out '%{http_version}' \
  "https://$server_name/") || die "VPS 无法通过 TLS 1.3 连接 $server_name。"
[[ $http_version == 2 ]] || die "$server_name 未与这台 VPS 协商 HTTP/2。"

work_dir=$(mktemp -d)
staging_dir=
cleanup() {
  rm -rf -- "$work_dir"
  if [[ -n $staging_dir ]]; then
    rm -rf -- "$staging_dir"
  fi
}
trap cleanup EXIT

if [[ ! -x $xray ]]; then
  printf '正在通过 XTLS 官方安装程序安装 Xray…\n'
  curl --fail --silent --show-error --location --max-time 30 \
    "$installer_url" --output "$work_dir/xray-install.sh"
  bash "$work_dir/xray-install.sh" install --without-geodata 9>&-
fi
[[ -f $config_file ]] && systemctl cat xray.service >/dev/null ||
  die "找不到 Xray 的默认 systemd 服务或配置文件。"

uuid=$("$xray" uuid)
key_pair=$("$xray" x25519)
private_key=$(awk '/^Private[Kk]ey:/ {print $NF}' <<< "$key_pair")
public_key=$(awk '/^(Password|Public[Kk]ey)[[:space:]:]/ {print $NF}' <<< "$key_pair")
short_id=$(openssl rand -hex 8)
[[ $uuid =~ ^[0-9a-f-]{36}$ && $private_key =~ ^[A-Za-z0-9_-]{43}$ &&
   $public_key =~ ^[A-Za-z0-9_-]{43}$ && $short_id =~ ^[0-9a-f]{16}$ ]] ||
  die "无法生成 VLESS 凭据，请检查 Xray 版本。"

staging_dir=$(mktemp -d "$config_dir/.reality.XXXXXX")
cp -p -- "$config_file" "$staging_dir/previous.json"
candidate="$staging_dir/config.json"
cat > "$candidate" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "target": "$server_name:443",
        "serverNames": ["$server_name"],
        "privateKey": "$private_key",
        "shortIds": ["$short_id"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

"$xray" run -test -config "$candidate"
chown --reference="$config_file" "$candidate"
chmod --reference="$config_file" "$candidate"
mv -f -- "$candidate" "$config_file"

if ! enable_bbr_fq; then
  printf '提示：BBR/FQ 未能完整启用，继续安装 Xray。\n' >&2
fi

listening=false
if systemctl restart xray.service; then
  for attempt in 1 2 3 4 5; do
    if systemctl is-active --quiet xray.service &&
       ss -H -ltnp "sport = :$port" | awk '/users:.*"xray"/ {found=1} END {exit !found}'; then
      listening=true
      break
    fi
    sleep 1
  done
fi
if [[ $listening != true ]]; then
  journalctl -u xray.service -n 15 --no-pager >&2 || true
  mv -f -- "$staging_dir/previous.json" "$config_file"
  systemctl restart xray.service || true
  die "Xray 未能监听 TCP $port，已恢复原配置。"
fi

link="vless://$uuid@$public_ip:$port?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=$server_name&fp=chrome&pbk=$public_key&sid=$short_id#$public_ip"
printf '%s\n' "$link" > "$link_file"
printf '\n安装完成。请在 VPS 的云防火墙放行入站 TCP %s，再把以下链接导入客户端。\n' "$port"
printf '链接包含节点凭据，请自行保管。副本保存在 %s。\n\n%s\n' "$link_file" "$link"
