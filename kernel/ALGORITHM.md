# X420 coupled network stack

## Scope

X420 is a research prototype for a Linux 6.18.39 LTS sender running Xray,
VLESS, REALITY, and RAW/TCP. It does not change the wire protocol and does not
require a modified client. It changes only the server's TCP sender and egress
queue.

The design has three explicit roles:

1. Xray supplies flow intent through `SO_MARK` and selects `x420` with
   `TCP_CONGESTION`.
2. X420-CC estimates path capacity and sets congestion window and pacing rate.
3. X420-Q isolates flows, applies weighted service, and executes socket pacing.

No component is allowed to become a second independent rate controller.

## Shared flow contract

The upper sixteen mark bits contain the magic `0x0420`. The low byte contains
the flow class.

| Mark | Class | X420-Q band |
|---|---|---|
| `0x04200001` | REALITY handshake | latency |
| `0x04200002` | interactive | latency |
| `0x04200003` | steady proxy stream | steady |
| `0x04200004` | bulk transfer | bulk |
| `0x04200005` | idle restart | steady |

Unmarked traffic retains the standard FQ priority mapping. The supplied Xray
fragment uses steady class `0x04200003`. Dynamic phase marking requires an
additional Xray-core change and is not implemented in this prototype.

## X420-CC model

For a valid delivery-rate sample:

```text
bandwidth_sample = delivered_packets / interval
BDP = estimated_bandwidth × minimum_RTT
queue_delay = current_RTT - minimum_RTT
target_inflight = BDP × cwnd_gain
```

The bandwidth estimate accepts higher application-limited samples but rejects
lower ones. Non-application-limited estimates decay gradually when path
capacity remains lower.

The minimum RTT filter expires after ten seconds. X420 deliberately does not
force a disruptive ProbeRTT phase in this first prototype.

### States

- `STARTUP`: pace at 2.0 times the bandwidth estimate until three rounds pass
  without at least 12.5% bandwidth growth.
- `DRAIN`: pace at 0.75 until inflight data reaches one BDP.
- `CRUISE`: normally pace at 1.0, with one 1.10 probe round followed by one
  0.90 drain round in every eight rounds.

Persistent queue growth overrides state gains:

- queue delay above the target: pacing gain 0.90;
- queue delay above twice the target: pacing gain 0.75.

The default queue target is 12% of minimum RTT, clamped between 2 ms and
20 ms. Module parameters expose the bounds and gains for controlled tests.

Loss reduces cwnd to 87.5% by default. This is intentionally milder than a
classic multiplicative halving because queue delay already supplies an earlier
signal. It must be tested for coexistence before public deployment.

## X420-Q model

X420-Q derives from Linux FQ in the exact 6.18.39 LTS tree. It preserves:

- per-socket flow isolation;
- new/old flow round robin;
- socket pacing through `sk_pacing_rate`;
- delayed-flow scheduling and watchdog handling;
- flow limits, horizon checks, and standard netlink FQ attributes.

The refactor changes:

- mark-aware mapping into latency, steady, and bulk bands;
- band weights from `9:3:1` to `12:4:1`;
- a default 5 ms ECN threshold for packets late against their pacing time;
- a separate `x420q` qdisc identity, leaving standard `fq` available.

Weights provide bounded preference, not strict priority, so bulk flows cannot
be permanently starved.

## Stability rules

- Xray classifies; it does not calculate a rate.
- X420-CC calculates rate; it does not reorder flows.
- X420-Q executes rate and fairness; it does not estimate path bandwidth.
- CUBIC and FQ remain compiled and are the recovery profile.
- X420 modules are not selected as kernel defaults.
- Activation affects only new TCP sockets.

## Required validation

At minimum, compare CUBIC+FQ, BBR+FQ, X420+FQ, and X420+X420-Q across:

| Variable | Suggested points |
|---|---|
| RTT | 20, 80, 180 ms |
| Random loss | 0, 0.1, 1, 3% |
| Bottleneck rate | 20, 100, 1000 Mbit/s |
| Jitter | 0, 5, 20 ms |
| Concurrent flows | 1, 8, 64 |

Measure goodput, P50/P95/P99 RTT under load, retransmissions, Jain fairness,
handshake completion time, CPU cost, and idle-restart bursts. A throughput-only
speed test is not sufficient evidence of safety or improvement.
