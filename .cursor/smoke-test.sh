#!/usr/bin/env bash
# Self-contained end-to-end smoke test for the VLESS + REALITY + Vision tunnel
# that the installer scripts deploy. It runs an xray server and client directly
# on this machine (no systemd required), then drives real traffic through the
# tunnel. Exits non-zero if the tunnel cannot carry traffic.
#
# Usage: bash .cursor/smoke-test.sh
set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
PORT="${PORT:-18443}"
SOCKS_PORT="${SOCKS_PORT:-19080}"
SNI="${SNI:-www.cloudflare.com}"
DEST="${DEST:-www.cloudflare.com:443}"
SELF_TEST_URL="${SELF_TEST_URL:-https://www.gstatic.com/generate_204}"

command -v "$XRAY_BIN" >/dev/null 2>&1 || {
  echo "xray not found at $XRAY_BIN; run .cursor/install.sh first" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/vless-smoke.XXXXXX)"
server_pid="" client_pid=""
cleanup() {
  if [[ -n "$client_pid" ]]; then kill "$client_pid" >/dev/null 2>&1 || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" >/dev/null 2>&1 || true; fi
  wait >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== Generating REALITY identity =="
UUID_VALUE="$("$XRAY_BIN" uuid)"
pair="$("$XRAY_BIN" x25519)"
PRIVATE_KEY="$(printf '%s\n' "$pair" | awk -F': ' '/PrivateKey:|Private key:/ {print $2; exit}')"
PUBLIC_KEY="$(printf '%s\n' "$pair" | awk -F': ' '/Password \(PublicKey\):|Public key:/ {print $2; exit}')"
SHORT_ID="$(openssl rand -hex 8)"
echo "uuid=$UUID_VALUE publicKey=$PUBLIC_KEY shortId=$SHORT_ID"

cat >"$WORK/server.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "127.0.0.1", "port": $PORT, "protocol": "vless",
    "settings": { "clients": [{ "id": "$UUID_VALUE", "flow": "xtls-rprx-vision" }], "decryption": "none" },
    "streamSettings": { "network": "raw", "security": "reality",
      "realitySettings": { "show": false, "dest": "$DEST", "xver": 0,
        "serverNames": ["$SNI"], "privateKey": "$PRIVATE_KEY", "shortIds": ["$SHORT_ID"] } },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

cat >"$WORK/client.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "listen": "127.0.0.1", "port": $SOCKS_PORT, "protocol": "socks", "settings": { "udp": true } }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "127.0.0.1", "port": $PORT,
      "users": [{ "id": "$UUID_VALUE", "encryption": "none", "flow": "xtls-rprx-vision" }] }] },
    "streamSettings": { "network": "raw", "security": "reality",
      "realitySettings": { "fingerprint": "chrome", "serverName": "$SNI",
        "publicKey": "$PUBLIC_KEY", "shortId": "$SHORT_ID", "spiderX": "/" } }
  }]
}
EOF

echo "== Validating configs =="
"$XRAY_BIN" run -test -c "$WORK/server.json" >/dev/null && echo "server config valid"
"$XRAY_BIN" run -test -c "$WORK/client.json" >/dev/null && echo "client config valid"

echo "== Starting tunnel =="
"$XRAY_BIN" run -c "$WORK/server.json" >"$WORK/server.log" 2>&1 &
server_pid="$!"
"$XRAY_BIN" run -c "$WORK/client.json" >"$WORK/client.log" 2>&1 &
client_pid="$!"
sleep 3

echo "== Driving traffic through tunnel: $SELF_TEST_URL =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  --socks5-hostname "127.0.0.1:$SOCKS_PORT" "$SELF_TEST_URL")"
echo "HTTP status via tunnel: $code"

if [[ "$code" == "204" || "$code" == "200" ]]; then
  echo "SMOKE TEST: PASS"
else
  echo "SMOKE TEST: FAIL (status $code)" >&2
  echo "--- server log ---" >&2
  tail -40 "$WORK/server.log" >&2
  echo "--- client log ---" >&2
  tail -40 "$WORK/client.log" >&2
  exit 1
fi
