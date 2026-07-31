#!/usr/bin/env bash
set -euo pipefail

if ((EUID != 0)); then
  echo "run as root: sudo $0" >&2
  exit 1
fi

systemctl disable --now vps-network-tune.service 2>/dev/null || true
rm -f /etc/systemd/system/vps-network-tune.service
rm -f /usr/local/libexec/vps-network-tune
rm -f /usr/local/sbin/vps-queuectl
rm -f /etc/sysctl.d/90-vps-proxy.conf
rm -f /etc/sysctl.d/99-vps-proxy.conf
rm -rf -- /var/lib/vps-queuectl
systemctl daemon-reload

echo "removed project tuning files; reboot to restore distribution defaults"
