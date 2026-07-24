#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
	echo "Run as root: sudo $0" >&2
	exit 1
fi

STATE_FILE=/run/bbrq-previous-settings
QDISC=fq_codel
CC=cubic

if [[ -r "${STATE_FILE}" ]]; then
	# The state file is root-owned and created by activate-bbrq.sh.
	# shellcheck disable=SC1090
	source "${STATE_FILE}"
fi

sysctl -w "net.ipv4.tcp_congestion_control=${CC}"
sysctl -w "net.core.default_qdisc=${QDISC}"
modprobe -r tcp_bbrq 2>/dev/null || true

echo "Restored congestion control=${CC}, qdisc=${QDISC} for new connections."
