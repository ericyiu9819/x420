#!/usr/bin/env bash
# Activate X420 for new TCP connections on one explicitly selected interface.
# This script does not install a kernel and refuses to guess the interface.

set -Eeuo pipefail
umask 077

IFACE=""
CONFIRM=0
STATE_DIR="/var/lib/x420"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ACTIVATION_STARTED=0

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

recover_on_error() {
	local status=$?

	if ((ACTIVATION_STARTED)); then
		sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 ||
			true
		tc qdisc replace dev "$IFACE" root fq >/dev/null 2>&1 || true
	fi
	printf 'ERROR: Activation failed; attempted CUBIC + FQ recovery.\n' >&2
	exit "$status"
}

trap recover_on_error ERR

while (($#)); do
	case "$1" in
		--iface)
			[[ $# -ge 2 ]] || fail "--iface requires a value"
			IFACE="$2"
			shift 2
			;;
		--confirm)
			CONFIRM=1
			shift
			;;
		-h|--help)
			printf 'Usage: sudo %s --iface DEVICE --confirm\n' "$0"
			exit 0
			;;
		*)
			fail "Unknown argument: $1"
			;;
	esac
done

[[ $EUID -eq 0 ]] || fail "Run as root."
[[ -n "$IFACE" ]] || fail "Specify the exact egress interface with --iface."
[[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "Invalid interface name."
[[ -d "/sys/class/net/$IFACE" ]] || fail "Interface does not exist: $IFACE"
((CONFIRM)) || fail "Re-run with --confirm after reviewing the target interface."

command -v tc >/dev/null || fail "The iproute2 tc command is required."
command -v sysctl >/dev/null || fail "sysctl is required."

install -d -m 0700 "$STATE_DIR"
install -m 0700 "$SCRIPT_DIR/rollback-x420-profile.sh" \
	"$STATE_DIR/rollback.sh"
date -u +%FT%TZ >"$STATE_DIR/activated-at"
sysctl -n net.ipv4.tcp_congestion_control \
	>"$STATE_DIR/previous-congestion-control"
tc qdisc show dev "$IFACE" >"$STATE_DIR/previous-qdisc.txt"
printf '%s\n' "$IFACE" >"$STATE_DIR/interface"

note "Loading experimental modules"
modprobe tcp_x420
modprobe sch_x420q
grep -qw x420 /proc/sys/net/ipv4/tcp_available_congestion_control ||
	fail "The x420 congestion controller is unavailable."

note "Activating X420 for new TCP sockets"
ACTIVATION_STARTED=1
sysctl -w net.ipv4.tcp_congestion_control=x420
tc qdisc replace dev "$IFACE" root x420q

[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "x420" ]] ||
	fail "Congestion-control activation did not persist."
tc qdisc show dev "$IFACE" | grep -qw x420q ||
	fail "X420Q activation did not persist."
ACTIVATION_STARTED=0
trap - ERR

note "Profile active"
printf '%s\n' \
	"Interface: $IFACE" \
	"Fallback: sudo $STATE_DIR/rollback.sh" \
	"Only new TCP sockets inherit x420; restart Xray during a maintenance window."
