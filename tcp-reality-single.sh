#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TEST_URL="https://www.gstatic.com/generate_204"

usage() {
  cat <<'EOF'
TCP REALITY 单方案脚本

目标：
  单协议、单出口、TCP only、低冗余、中等以上混淆性。
  使用 Xray VLESS + REALITY + Vision over TCP/443 作为唯一代理协议。

子命令：
  plan                 输出方案逻辑
  make-secrets         生成 UUID、short_id、随机占位密码材料
  gen-server           生成 Xray 服务端配置
  gen-client           生成 sing-box 客户端配置
  gen-shadowrocket-uri 生成 Shadowrocket 可导入的 VLESS Reality URI
  gen-shadowrocket-qr  生成 Shadowrocket URI 二维码 SVG/PNG
  gen-qr               根据任意导入链接生成二维码 SVG/PNG
  install-server       安装 Xray 配置到 /usr/local/etc/xray/config.json
  tune-server          应用保守 TCP/BBR/sysctl 优化
  firewall-server      UFW 仅放行 22/tcp 和 443/tcp
  harden-ssh           禁用 SSH 密码登录，保留密钥登录
  observe              观测系统、端口、连接、代理进程资源
  probe-proxy          经本地 SOCKS5 测代理路径延迟
  probe-direct         测本机直连目标延迟
  validate             生成并校验 JSON 模板

常用：
  ./tcp-reality-single.sh make-secrets > secrets.env
  . ./secrets.env
  ./tcp-reality-single.sh gen-server > xray-server.json
  ./tcp-reality-single.sh gen-client > sing-box-client.json
  ./tcp-reality-single.sh gen-shadowrocket-qr shadowrocket.svg
  ./tcp-reality-single.sh gen-qr shadowrocket.svg 'vless://...'
  ./tcp-reality-single.sh validate

关键环境变量：
  SERVER_ADDR                VPS 域名或 IP
  XRAY_UUID                  VLESS UUID
  REALITY_SERVER_NAME        REALITY server_name / SNI
  REALITY_TARGET_DOMAIN      REALITY dest 域名
  REALITY_PRIVATE_KEY        xray x25519 生成的私钥
  REALITY_PUBLIC_KEY         xray x25519 生成的公钥
  REALITY_SHORT_ID           short_id，建议 8-16 hex
  PRIVATE_DOMAINS            本地域名后缀，逗号分隔，默认 lan,local
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: 该子命令需要 root 权限，请使用 sudo。" >&2
    exit 1
  fi
}

csv_to_json_strings() {
  local csv="${1:-lan,local}"
  local out=""
  local item
  local -a items=()
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -z "$item" ]] && continue
    [[ -n "$out" ]] && out+=", "
    out+="\"$item\""
  done
  [[ -z "$out" ]] && out='"lan", "local"'
  printf '%s' "$out"
}

plan() {
  cat <<'EOF'
单方案：VLESS + REALITY + Vision over TCP/443

工程取舍：
  - 不使用 UDP，规避 WireGuard/Hysteria2 在当前网络下的断流问题。
  - 不使用 trojan-go，避免继续投入到当前已验证较慢的 TCP/TLS 实现。
  - 不使用 selector/urltest/fallback，减少探测、切换抖动和配置复杂度。
  - 不做链式代理，降低 RTT、CPU、连接状态和排障成本。
  - 私有地址和本地域名直连，减少无效代理流量。

数据路径：
  应用 -> 本地 sing-box SOCKS/HTTP/TUN -> VLESS REALITY TCP/443 -> Xray Server -> 目标

效率点：
  - Xray 服务端只保留一个 inbound 和 direct/block outbound。
  - 客户端只保留一个 proxy outbound，无自动测速组。
  - SSH/网页/Git 都走同一 TCP 传输，便于观测和排障。
  - BBR + fq + 保守队列参数改善 TCP 拥塞表现。
  - 只记录 warning 级日志，减少 IO 和敏感信息暴露。
EOF
}

make_secrets() {
  local uuid short
  if command -v xray >/dev/null 2>&1; then
    uuid="$(xray uuid)"
  elif command -v uuidgen >/dev/null 2>&1; then
    uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    uuid="<GENERATE_UUID>"
  fi
  short="$(openssl rand -hex 8 2>/dev/null || printf '<REALITY_SHORT_ID>')"
  cat <<EOF
export SERVER_ADDR="<VPS_DOMAIN_OR_IP>"
export XRAY_UUID="${uuid}"
export REALITY_SHORT_ID="${short}"

# 运行 xray x25519 后填写：
export REALITY_PRIVATE_KEY="<REALITY_PRIVATE_KEY>"
export REALITY_PUBLIC_KEY="<REALITY_PUBLIC_KEY>"

# 建议选择稳定 HTTPS 站点域名；server_name 与客户端一致。
export REALITY_SERVER_NAME="<REALITY_SERVER_NAME>"
export REALITY_TARGET_DOMAIN="<REALITY_TARGET_DOMAIN>"

export PRIVATE_DOMAINS="lan,local"
EOF
}

gen_server() {
  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${SERVER_PORT:-443},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID:-<XRAY_UUID>}",
            "flow": "xtls-rprx-vision",
            "email": "self-use"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_TARGET_DOMAIN:-<REALITY_TARGET_DOMAIN>}:443",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAME:-<REALITY_SERVER_NAME>}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY:-<REALITY_PRIVATE_KEY>}",
          "shortIds": [
            "${REALITY_SHORT_ID:-<REALITY_SHORT_ID>}"
          ]
        }
      },
      "sniffing": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

gen_client() {
  local private_domains
  private_domains="$(csv_to_json_strings "${PRIVATE_DOMAINS:-lan,local}")"
  cat <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": ${SOCKS_PORT:-1080},
      "sniff": true
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "127.0.0.1",
      "listen_port": ${HTTP_PORT:-8080},
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_ADDR:-<VPS_DOMAIN_OR_IP>}",
      "server_port": ${SERVER_PORT:-443},
      "uuid": "${XRAY_UUID:-<XRAY_UUID>}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME:-<REALITY_SERVER_NAME>}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY:-<REALITY_PUBLIC_KEY>}",
          "short_id": "${REALITY_SHORT_ID:-<REALITY_SHORT_ID>}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "domain_suffix": [
          ${private_domains}
        ],
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
EOF
}

gen_shadowrocket_uri() {
  local label="${NODE_LABEL:-tcp-reality}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "${XRAY_UUID:-<XRAY_UUID>}" \
    "${SERVER_ADDR:-<VPS_DOMAIN_OR_IP>}" \
    "${SERVER_PORT:-443}" \
    "${REALITY_SERVER_NAME:-<REALITY_SERVER_NAME>}" \
    "${REALITY_PUBLIC_KEY:-<REALITY_PUBLIC_KEY>}" \
    "${REALITY_SHORT_ID:-<REALITY_SHORT_ID>}" \
    "${label}"
}

write_qr() {
  local output="${1:-shadowrocket-reality.svg}"
  local uri="${2:-}"
  if [[ -z "$uri" ]]; then
    uri="$(cat)"
  fi
  if [[ -z "$uri" ]]; then
    echo "error: 缺少导入链接。用法：gen-qr <output.svg|output.png> '<URI>'，或通过 stdin 传入。" >&2
    exit 1
  fi

  case "$output" in
    *.png)
      if command -v qrencode >/dev/null 2>&1; then
        printf '%s' "$uri" | qrencode -t PNG -o "$output" -m 2 -s 8
        echo "二维码已生成：$output"
        return 0
      fi
      echo "warning: 未找到 qrencode，改为生成 SVG：${output%.png}.svg" >&2
      output="${output%.png}.svg"
      ;;
    *.svg) ;;
    *)
      output="${output}.svg"
      ;;
  esac

  QR_PAYLOAD="$uri" QR_OUTPUT="$output" python3 - <<'PY'
import os

data = os.environ["QR_PAYLOAD"].encode("utf-8")
out = os.environ["QR_OUTPUT"]

MODE_BYTE = 0b0100
ECC_L = 1

CAPACITY_L = {
    1: 19, 2: 34, 3: 55, 4: 80, 5: 108, 6: 136, 7: 156, 8: 194,
    9: 232, 10: 274, 11: 324, 12: 370, 13: 428, 14: 461, 15: 523,
    16: 589, 17: 647, 18: 721, 19: 795, 20: 861, 21: 932, 22: 1006,
    23: 1094, 24: 1174, 25: 1276, 26: 1370, 27: 1468, 28: 1531,
    29: 1631, 30: 1735, 31: 1843, 32: 1955, 33: 2071, 34: 2191,
    35: 2306, 36: 2434, 37: 2566, 38: 2702, 39: 2812, 40: 2956,
}

# Reed-Solomon block metadata for ECC L: version -> (ec codewords per block, group1 blocks, group1 data, group2 blocks, group2 data)
RS_L = {
    1:(7,1,19,0,0), 2:(10,1,34,0,0), 3:(15,1,55,0,0), 4:(20,1,80,0,0),
    5:(26,1,108,0,0), 6:(18,2,68,0,0), 7:(20,2,78,0,0), 8:(24,2,97,0,0),
    9:(30,2,116,0,0), 10:(18,2,68,2,69), 11:(20,4,81,0,0), 12:(24,2,92,2,93),
    13:(26,4,107,0,0), 14:(30,3,115,1,116), 15:(22,5,87,1,88), 16:(24,5,98,1,99),
    17:(28,1,107,5,108), 18:(30,5,120,1,121), 19:(28,3,113,4,114), 20:(28,3,107,5,108),
    21:(28,4,116,4,117), 22:(28,2,111,7,112), 23:(30,4,121,5,122), 24:(30,6,117,4,118),
    25:(26,8,106,4,107), 26:(28,10,114,2,115), 27:(30,8,122,4,123), 28:(30,3,117,10,118),
    29:(30,7,116,7,117), 30:(30,5,115,10,116), 31:(30,13,115,3,116), 32:(30,17,115,0,0),
    33:(30,17,115,1,116), 34:(30,13,115,6,116), 35:(30,12,121,7,122), 36:(30,6,121,14,122),
    37:(30,17,122,4,123), 38:(30,4,122,18,123), 39:(30,20,117,4,118), 40:(30,19,118,6,119),
}

ALIGN = {
    1:[], 2:[6,18], 3:[6,22], 4:[6,26], 5:[6,30], 6:[6,34], 7:[6,22,38],
    8:[6,24,42], 9:[6,26,46], 10:[6,28,50], 11:[6,30,54], 12:[6,32,58],
    13:[6,34,62], 14:[6,26,46,66], 15:[6,26,48,70], 16:[6,26,50,74],
    17:[6,30,54,78], 18:[6,30,56,82], 19:[6,30,58,86], 20:[6,34,62,90],
    21:[6,28,50,72,94], 22:[6,26,50,74,98], 23:[6,30,54,78,102],
    24:[6,28,54,80,106], 25:[6,32,58,84,110], 26:[6,30,58,86,114],
    27:[6,34,62,90,118], 28:[6,26,50,74,98,122], 29:[6,30,54,78,102,126],
    30:[6,26,52,78,104,130], 31:[6,30,56,82,108,134], 32:[6,34,60,86,112,138],
    33:[6,30,58,86,114,142], 34:[6,34,62,90,118,146], 35:[6,30,54,78,102,126,150],
    36:[6,24,50,76,102,128,154], 37:[6,28,54,80,106,132,158],
    38:[6,32,58,84,110,136,162], 39:[6,26,54,82,110,138,166],
    40:[6,30,58,86,114,142,170],
}

def choose_version(n):
    # Byte mode character count uses 16 bits for v10+, so account for overhead.
    for v, cap in CAPACITY_L.items():
        overhead = 4 + (8 if v <= 9 else 16)
        needed_bits = overhead + n * 8
        if needed_bits <= cap * 8:
            return v
    raise SystemExit("URI 太长，超出 QR Code version 40-L 容量")

def bits_append(bits, val, length):
    for i in range(length - 1, -1, -1):
        bits.append((val >> i) & 1)

def gf_mul(x, y):
    z = 0
    while y:
        if y & 1:
            z ^= x
        x <<= 1
        if x & 0x100:
            x ^= 0x11D
        y >>= 1
    return z

def rs_generator(degree):
    poly = [1]
    root = 1
    for _ in range(degree):
        poly = [gf_mul(c, root) for c in poly] + [0]
        for j in range(len(poly) - 1):
            poly[j + 1] ^= poly[j]
        root = gf_mul(root, 2)
    return poly

def rs_remainder(block, degree):
    gen = rs_generator(degree)
    rem = [0] * degree
    for b in block:
        factor = b ^ rem.pop(0)
        rem.append(0)
        for i in range(degree):
            rem[i] ^= gf_mul(gen[i], factor)
    return rem

def make_codewords(version, raw):
    ec_len, g1b, g1d, g2b, g2d = RS_L[version]
    total_data = g1b * g1d + g2b * g2d
    bits = []
    bits_append(bits, MODE_BYTE, 4)
    bits_append(bits, len(raw), 8 if version <= 9 else 16)
    for b in raw:
        bits_append(bits, b, 8)
    max_bits = total_data * 8
    bits += [0] * min(4, max_bits - len(bits))
    while len(bits) % 8:
        bits.append(0)
    pads = [0xEC, 0x11]
    i = 0
    while len(bits) < max_bits:
        bits_append(bits, pads[i % 2], 8)
        i += 1
    data_cw = [sum(bits[i + j] << (7 - j) for j in range(8)) for i in range(0, len(bits), 8)]
    blocks = []
    p = 0
    for _ in range(g1b):
        blk = data_cw[p:p+g1d]; p += g1d
        blocks.append((blk, rs_remainder(blk, ec_len)))
    for _ in range(g2b):
        blk = data_cw[p:p+g2d]; p += g2d
        blocks.append((blk, rs_remainder(blk, ec_len)))
    result = []
    max_data = max(len(b[0]) for b in blocks)
    for i in range(max_data):
        for blk, _ in blocks:
            if i < len(blk):
                result.append(blk[i])
    for i in range(ec_len):
        for _, ecc in blocks:
            result.append(ecc[i])
    return result

def draw_finder(m, r, c):
    n = len(m)
    for y in range(r - 1, r + 8):
        for x in range(c - 1, c + 8):
            if 0 <= y < n and 0 <= x < n:
                m[y][x] = False
    for y in range(r, r + 7):
        for x in range(c, c + 7):
            m[y][x] = (y in (r, r + 6) or x in (c, c + 6) or (r + 2 <= y <= r + 4 and c + 2 <= x <= c + 4))

def draw_alignment(m, r, c):
    for y in range(r - 2, r + 3):
        for x in range(c - 2, c + 3):
            m[y][x] = (abs(y-r) == 2 or abs(x-c) == 2 or (y == r and x == c))

def reserve_function(n):
    m = [[None] * n for _ in range(n)]
    draw_finder(m, 0, 0)
    draw_finder(m, 0, n - 7)
    draw_finder(m, n - 7, 0)
    for i in range(8, n - 8):
        m[6][i] = (i % 2 == 0)
        m[i][6] = (i % 2 == 0)
    for i in range(9):
        if m[8][i] is None: m[8][i] = False
        if m[i][8] is None: m[i][8] = False
        if m[8][n - 1 - i] is None: m[8][n - 1 - i] = False
        if m[n - 1 - i][8] is None: m[n - 1 - i][8] = False
    m[n - 8][8] = True
    return m

def place_data(m, codewords):
    n = len(m)
    bits = []
    for b in codewords:
        bits += [(b >> i) & 1 for i in range(7, -1, -1)]
    i = 0
    upward = True
    x = n - 1
    while x > 0:
        if x == 6:
            x -= 1
        rows = range(n - 1, -1, -1) if upward else range(n)
        for y in rows:
            for xx in (x, x - 1):
                if m[y][xx] is None:
                    bit = bits[i] if i < len(bits) else 0
                    # Mask pattern 0: (row + col) % 2 == 0.
                    m[y][xx] = bool(bit ^ (((y + xx) % 2) == 0))
                    i += 1
        upward = not upward
        x -= 2

def format_bits():
    # ECC L, mask 0 -> data bits 01 000.
    data = 0b01000
    val = data << 10
    poly = 0b10100110111
    for i in range(14, 9, -1):
        if (val >> i) & 1:
            val ^= poly << (i - 10)
    return ((data << 10) | val) ^ 0b101010000010010

def draw_format(m):
    n = len(m)
    bits = [(format_bits() >> i) & 1 for i in range(14, -1, -1)]
    coords1 = [(8,0),(8,1),(8,2),(8,3),(8,4),(8,5),(8,7),(8,8),(7,8),(5,8),(4,8),(3,8),(2,8),(1,8),(0,8)]
    coords2 = [(n-1,8),(n-2,8),(n-3,8),(n-4,8),(n-5,8),(n-6,8),(n-7,8),(8,n-8),(8,n-7),(8,n-6),(8,n-5),(8,n-4),(8,n-3),(8,n-2),(8,n-1)]
    for bit, (y, x) in zip(bits, coords1):
        m[y][x] = bool(bit)
    for bit, (y, x) in zip(bits, coords2):
        m[y][x] = bool(bit)

version = choose_version(len(data))
n = 21 + 4 * (version - 1)
m = reserve_function(n)
for r in ALIGN[version]:
    for c in ALIGN[version]:
        if (r <= 8 and c <= 8) or (r <= 8 and c >= n - 9) or (r >= n - 9 and c <= 8):
            continue
        draw_alignment(m, r, c)
place_data(m, make_codewords(version, data))
draw_format(m)

quiet = 4
scale = 8
size = (n + quiet * 2) * scale
rects = []
for y, row in enumerate(m):
    for x, v in enumerate(row):
        if v:
            rects.append(f'<rect x="{(x+quiet)*scale}" y="{(y+quiet)*scale}" width="{scale}" height="{scale}"/>')
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">
<rect width="100%" height="100%" fill="#fff"/>
<g fill="#000">
{''.join(rects)}
</g>
</svg>
'''
with open(out, "w", encoding="utf-8") as f:
    f.write(svg)
PY
  echo "二维码已生成：$output"
}

gen_shadowrocket_qr() {
  local output="${1:-shadowrocket-reality.svg}"
  local uri="${2:-}"
  if [[ -z "$uri" ]]; then
    uri="$(gen_shadowrocket_uri)"
  fi
  write_qr "$output" "$uri"
}

gen_qr() {
  local output="${1:-import-link.svg}"
  local uri="${2:-}"
  write_qr "$output" "$uri"
}

install_server() {
  need_root
  install -d -m 0755 /usr/local/etc/xray
  gen_server > /usr/local/etc/xray/config.json
  if getent passwd nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1; then
    chown nobody:nogroup /usr/local/etc/xray/config.json
  fi
  chmod 600 /usr/local/etc/xray/config.json
  if command -v xray >/dev/null 2>&1; then
    xray run -test -config /usr/local/etc/xray/config.json
  else
    echo "warning: 未找到 xray，跳过配置自检。"
  fi
  echo "已写入 /usr/local/etc/xray/config.json"
}

tune_server() {
  need_root
  modprobe tcp_bbr || true
  printf 'tcp_bbr\n' > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-tcp-reality-single.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.ip_local_port_range=10240 60999
net.ipv4.tcp_mtu_probing=1
EOF
  sysctl --system
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing
}

firewall_server() {
  need_root
  if ! command -v ufw >/dev/null 2>&1; then
    echo "error: 未找到 ufw，请先安装 ufw 或手动配置防火墙。" >&2
    exit 1
  fi
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow "${SERVER_PORT:-443}/tcp"
  ufw --force enable
  ufw status verbose
}

harden_ssh() {
  need_root
  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
  sed -i \
    -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
    -e 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' \
    /etc/ssh/sshd_config
  sshd -t
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  echo "SSH 已禁用密码登录；请确认密钥登录可用后再关闭当前会话。"
}

observe() {
  local target="${1:-1.1.1.1}"
  local count="${2:-10}"
  echo "== system =="
  uname -a
  uptime
  echo
  echo "== cpu/mem =="
  top -b -n 1 | head -n 15 || true
  free -h || true
  echo
  echo "== connections =="
  ss -s || true
  echo
  echo "== listening tcp =="
  ss -tlpen || true
  echo
  echo "== ping ${target} =="
  ping -c "$count" "$target" || true
  echo
  echo "== xray/sing-box process =="
  ps -eo pid,comm,%cpu,%mem,rss,vsz,etime,args | grep -E 'xray|sing-box' | grep -v grep || true
}

probe_proxy() {
  local proxy="${1:-socks5h://127.0.0.1:1080}"
  local url="${2:-$DEFAULT_TEST_URL}"
  local count="${3:-20}"
  local i
  printf 'namelookup connect tls starttransfer total\n'
  for i in $(seq 1 "$count"); do
    curl -x "$proxy" -o /dev/null -s \
      -w "%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n" \
      "$url" || true
    sleep 1
  done
}

probe_direct() {
  local url="${1:-$DEFAULT_TEST_URL}"
  local count="${2:-10}"
  local i
  printf 'namelookup connect tls starttransfer total\n'
  for i in $(seq 1 "$count"); do
    curl -o /dev/null -s \
      -w "%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n" \
      "$url" || true
    sleep 1
  done
}

validate() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  gen_server > "$tmp/server.json"
  gen_client > "$tmp/client.json"
  python3 -m json.tool "$tmp/server.json" >/dev/null
  python3 -m json.tool "$tmp/client.json" >/dev/null
  bash -n "$0"
  echo "脚本语法、服务端 JSON、客户端 JSON 基础校验通过。"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  plan) plan "$@" ;;
  make-secrets) make_secrets "$@" ;;
  gen-server) gen_server "$@" ;;
  gen-client) gen_client "$@" ;;
  gen-shadowrocket-uri) gen_shadowrocket_uri "$@" ;;
  gen-shadowrocket-qr) gen_shadowrocket_qr "$@" ;;
  gen-qr) gen_qr "$@" ;;
  install-server) install_server "$@" ;;
  tune-server) tune_server "$@" ;;
  firewall-server) firewall_server "$@" ;;
  harden-ssh) harden_ssh "$@" ;;
  observe) observe "$@" ;;
  probe-proxy) probe_proxy "$@" ;;
  probe-direct) probe_direct "$@" ;;
  validate) validate "$@" ;;
  help|-h|--help) usage ;;
  *)
    echo "error: 未知子命令：$cmd" >&2
    usage >&2
    exit 1
    ;;
esac
