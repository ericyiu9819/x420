# x Network Efficiency Algorithm

## Goal

`x` is the control algorithm for the x420 TCP-only proxy path:

```text
client app -> sing-box local inbound -> VLESS REALITY TCP/443 -> Xray -> target
```

The algorithm maximizes useful throughput under explicit waste and latency
constraints. It intentionally does not chase the highest short iperf sample.

## Layers

The design has three layers:

```text
kernel:      BBR + fq pacing
runtime:     minimal sysctl profile
controller:  conservative probe and accept/reject logic
```

BBR estimates bandwidth and RTT for each TCP flow. `fq` gives BBR a pacing queue
that can actually shape packets. The controller only decides whether the current
network path can safely use more parallel application streams.

## Inputs

For each probe candidate, collect or derive:

```text
P             application parallelism
throughput    iperf3 Mbps
goodput       throughput discounted by retransmission waste
retransmits   iperf3 retransmission count
bytes_sent    iperf3 transferred bytes
retrans_rate  retransmits / estimated TCP segments
rtt_ms        median ss -tin RTT
rto_ms        median ss -tin RTO
cwnd          median ss -tin congestion window
pacing_mbps   median ss -tin pacing rate
queue_growth  (rtt_ms - min_rtt_ms) / min_rtt_ms
cpu_idle      mpstat idle percentage, when available
```

## Candidate Set

Use a tiny search space, with direction-aware defaults:

```text
upload:    P = 1, 2, 4, 8
download:  P = 1, 2, 4
```

For x420, a higher value is accepted only when it is both faster and clean. This
fits a self-use proxy better than aggressive parallel probing because most daily
traffic is latency-sensitive and connection-mixed.

## Acceptance Rules

A sample is usable only if:

```text
throughput_mbps > 0
goodput_mbps > 0
retrans_rate <= profile threshold
queue_growth <= profile threshold, when RTT is available
cpu_idle >= profile threshold, when CPU is available
```

A profile provides the thresholds:

```text
upload:    retrans_rate <= 0.0010, queue_growth <= 0.30, cpu_idle >= 20%
download:  retrans_rate <= 0.0005, queue_growth <= 0.20, cpu_idle >= 20%
```

A higher parallel level replaces the current best only if:

```text
gain = (candidate_mbps - best_mbps) / best_mbps
gain >= 0.10
candidate is usable
```

Stop probing immediately when:

```text
candidate throughput is zero
candidate retransmission rate exceeds 0.1%
gain < 10%
RTT grows above 130% of the best observed RTT
CPU idle falls below 20%
```

## Score

The score is only a diagnostic ranking. Acceptance is still controlled by the
hard rules above.

```text
goodput_mbps = throughput_mbps * (1 - min(retrans_rate, 0.50))
score = goodput_mbps

if rtt_ms > min_rtt_ms:
  queue_growth = (rtt_ms - min_rtt_ms) / min_rtt_ms
  score -= goodput_mbps * min(queue_growth, 2.0) * 0.35

if retrans_rate > 0:
  score -= goodput_mbps * min(retrans_rate * 100.0, 0.85)

if cpu_used > 80%:
  score -= goodput_mbps * 0.25
elif cpu_used > 70%:
  score -= goodput_mbps * 0.10
```

This prevents a noisy high-throughput sample from winning just because it is
numerically faster.

## Pseudocode

```text
best = none
min_rtt = none

for P in profile_candidates:
  sample = run_probe(P)
  min_rtt = min(min_rtt, sample.rtt_ms)
  sample.retrans_rate = sample.retransmits / estimated_segments
  sample.goodput = sample.throughput * (1 - min(sample.retrans_rate, 0.50))
  sample.score = score(sample, min_rtt)

  if best is none:
    best = sample
    continue

  gain = (sample.goodput_mbps - best.goodput_mbps) / best.goodput_mbps

  if sample.goodput_mbps <= 0:
    break

  if sample.retrans_rate > profile.max_retrans_rate:
    break

  if sample.cpu_idle is known and sample.cpu_idle < 20:
    break

  if sample.queue_growth is known and sample.queue_growth > profile.max_queue_growth:
    break

  if gain < 0.10:
    break

  best = sample

if no safe sample exists:
  return no recommendation

return best.parallel
```

## Runtime Policy

The controller may write only this sysctl profile:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
```

Do not dynamically tune `tcp_fastopen`, `tcp_fin_timeout`, `somaxconn`,
`tcp_max_syn_backlog`, or keepalive settings as part of this algorithm. Those are
service policy knobs, not core BBR efficiency knobs for this workload.

## Meaning For x420

For the current single-node proxy design:

```text
recommended_parallel=none
```

is sometimes the correct answer, even when `P=2` or `P=4` shows a larger iperf
number. If every candidate creates too much retransmission waste, zero goodput,
or RTT queue growth, the algorithm rejects the whole run instead of pretending
the least bad candidate is safe.

The practical target is:

```text
clean BBR pacing + low retransmission + predictable latency
```

not:

```text
maximum burst throughput during a synthetic test
```
