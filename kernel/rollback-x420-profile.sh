#!/usr/bin/env bash
# Return to the deliberately conservative CUBIC + FQ recovery profile.

set -Eeuo pipefail

STATE_DIR="/var/lib/x420"
[[ $EUID -eq 0 ]] || { printf 'ERROR: Run as root.\n' >&2; exit 1; }
[[ -r "$STATE_DIR/interface" ]] ||
	{ printf 'ERROR: No X420 state was recorded.\n' >&2; exit 1; }

IFACE="$(<"$STATE_DIR/interface")"
[[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ && -d "/sys/class/net/$IFACE" ]] ||
	{ printf 'ERROR: Recorded interface is invalid.\n' >&2; exit 1; }

sysctl -w net.ipv4.tcp_congestion_control=cubic
tc qdisc replace dev "$IFACE" root fq

printf 'Recovery profile active on %s: CUBIC + FQ\n' "$IFACE"
