#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
	echo "Run as root so the script can switch congestion control." >&2
	exit 1
fi
if [[ "$#" -lt 1 ]]; then
	echo "Usage: sudo $0 IPERF3_SERVER [SECONDS] [PARALLEL_STREAMS]" >&2
	exit 1
fi

SERVER="$1"
DURATION="${2:-30}"
STREAMS="${3:-4}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${RESULT_DIR:-${SCRIPT_DIR}/results-$(date +%Y%m%d-%H%M%S)}"
ORIGINAL_CC="$(sysctl -n net.ipv4.tcp_congestion_control)"
ORIGINAL_QDISC="$(sysctl -n net.core.default_qdisc)"

restore() {
	sysctl -q -w "net.ipv4.tcp_congestion_control=${ORIGINAL_CC}" || true
	sysctl -q -w "net.core.default_qdisc=${ORIGINAL_QDISC}" || true
}
trap restore EXIT

command -v iperf3 >/dev/null || { echo "iperf3 is required." >&2; exit 1; }
mkdir -p "${RESULT_DIR}"
modprobe tcp_bbr 2>/dev/null || true
modprobe tcp_bbrq 2>/dev/null || true
sysctl -q -w net.core.default_qdisc=fq

available=" $(sysctl -n net.ipv4.tcp_available_congestion_control) "
for algorithm in cubic bbr bbrq; do
	if [[ "${available}" != *" ${algorithm} "* ]]; then
		echo "Skipping unavailable algorithm: ${algorithm}"
		continue
	fi

	sysctl -q -w "net.ipv4.tcp_congestion_control=${algorithm}"
	sleep 2
	ping -c 20 -i 0.2 "${SERVER}" > "${RESULT_DIR}/${algorithm}-idle-ping.txt"
	iperf3 -c "${SERVER}" -t "${DURATION}" -P "${STREAMS}" -J \
		> "${RESULT_DIR}/${algorithm}-throughput.json"
	iperf3 -c "${SERVER}" -t "${DURATION}" -P 1 -R -J \
		> "${RESULT_DIR}/${algorithm}-reverse.json"
done

echo "Raw A/B results: ${RESULT_DIR}"
echo "Repeat at least five times and compare median throughput, retransmits, RTT and p95 latency under load."
