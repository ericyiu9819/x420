#!/usr/bin/env bash
set -euo pipefail

if ((EUID != 0)); then
  echo "run as root: sudo $0" >&2
  exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command in ip sysctl tc systemctl install; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

install -D -m 0644 \
  "$root_dir/deploy/99-vps-proxy.conf" \
  /etc/sysctl.d/99-vps-proxy.conf
install -D -m 0755 \
  "$root_dir/deploy/vps-network-tune" \
  /usr/local/sbin/vps-queuectl
rm -f /usr/local/libexec/vps-network-tune
install -D -m 0644 \
  "$root_dir/deploy/vps-network-tune.service" \
  /etc/systemd/system/vps-network-tune.service

systemctl daemon-reload
systemctl enable vps-network-tune.service
systemctl restart vps-network-tune.service

echo "installed: adaptive BBR + fq VPS proxy queue tuning"
"$root_dir/scripts/verify.sh"
