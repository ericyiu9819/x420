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
  qdisc_line="$(tc qdisc show dev "$interface" | awk '$1 == "qdisc" {print; exit}')"
  qdisc="$(awk '{print $2}' <<<"$qdisc_line")"
  check_equal "qdisc:${interface}" "$qdisc" "fq"

  if [[ -x /usr/local/sbin/vps-queuectl ]]; then
    plan="$(
      /usr/local/sbin/vps-queuectl plan --dev "$interface" --profile auto
    )"
    expected_quantum="$(
      sed -n 's/.* quantum \([0-9][0-9]*\) .*/\1/p' <<<"$plan"
    )"
    expected_flow_limit="$(
      sed -n 's/.* flow_limit \([0-9][0-9]*\) .*/\1/p' <<<"$plan"
    )"
    actual_quantum="$(
      sed -n 's/.* quantum \([0-9][0-9]*\)b.*/\1/p' <<<"$qdisc_line"
    )"
    actual_flow_limit="$(
      sed -n 's/.* flow_limit \([0-9][0-9]*\)p.*/\1/p' <<<"$qdisc_line"
    )"
    check_equal "quantum:${interface}" "$actual_quantum" "$expected_quantum"
    check_equal \
      "flow_limit:${interface}" \
      "$actual_flow_limit" \
      "$expected_flow_limit"
  fi
done < <(
  ip -o route show default |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' |
    sort -u
)

exit "$failures"
