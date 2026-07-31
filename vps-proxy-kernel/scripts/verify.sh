#!/usr/bin/env bash
set -euo pipefail

failures=0

check_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  if [[ "$actual" == "$expected" ]]; then
    printf 'ok   %-24s %s\n' "$label" "$actual"
  else
    printf 'FAIL %-24s expected=%s actual=%s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

check_equal \
  "congestion control" \
  "$(sysctl -n net.ipv4.tcp_congestion_control)" \
  "bbr"
check_equal \
  "default qdisc" \
  "$(sysctl -n net.core.default_qdisc)" \
  "fq"

if [[ -r /sys/module/tcp_bbr/parameters/full_bw_cnt ]] ||
   grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  printf 'ok   %-24s available\n' "BBR module"
else
  printf 'FAIL %-24s unavailable\n' "BBR module"
  failures=$((failures + 1))
fi

while read -r interface; do
  [[ -n "$interface" ]] || continue
  qdisc="$(tc qdisc show dev "$interface" | awk '$1 == "qdisc" {print $2; exit}')"
  check_equal "qdisc:${interface}" "$qdisc" "fq"
done < <(
  ip -o route show default |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' |
    sort -u
)

exit "$failures"
