#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
	echo "Run as root: sudo $0" >&2
	exit 1
fi

STATE_FILE=/run/bbrq-previous-settings
previous_qdisc="$(sysctl -n net.core.default_qdisc)"
previous_cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
printf 'QDISC=%q\nCC=%q\n' "${previous_qdisc}" "${previous_cc}" > "${STATE_FILE}"
chmod 600 "${STATE_FILE}"

modprobe sch_fq
modprobe tcp_bbrq

available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
if [[ " ${available} " != *" bbrq "* ]]; then
	echo "bbrq was not registered by the running kernel." >&2
	exit 1
fi

sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbrq

echo "BBRQ is active for new TCP connections only."
echo "Previous settings are recorded in ${STATE_FILE}."
