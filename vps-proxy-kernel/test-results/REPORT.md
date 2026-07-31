# VPS Proxy Kernel A/B Test

Test target: Cloudflare speed endpoints and `1.1.1.1`.

| Metric | 7.1.5 + EQS | 6.18.41 + FQ | Change |
|---|---:|---:|---:|
| Idle RTT average | 2.555 ms | 2.568 ms | +0.5% |
| 64 MB download | 655.5 Mbit/s | 756.8 Mbit/s | +15.5% |
| 32 MB upload | 296.6 Mbit/s | 636.2 Mbit/s | +114.5% |
| 128 MB loaded upload | 286.9 Mbit/s | 539.5 Mbit/s | +88.0% |
| Loaded RTT average | 2.613 ms | 3.223 ms | +23.3% |
| Loaded RTT maximum | 4.476 ms | 7.658 ms | +71.1% |
| Packet loss during ping tests | 0% | 0% | unchanged |

Final health checks:

- kernel: `6.18.41-vps-proxy`;
- congestion control: BBR;
- root qdisc: FQ;
- FQ drops/requeues/backlog: `0/0/0`;
- FQ reported scheduling latency: about 20 microseconds;
- Xray and SSH active with zero Xray restarts;
- external TCP ports 22 and 443 reachable;
- no failed systemd units;
- no error-level journal entries on the final boot;
- no swap in use after the tests.

These are short public-network samples, so they demonstrate direction rather
than laboratory-grade capacity. The final configuration favors proxy
throughput and CPU efficiency over strict egress shaping. The previous
7.1.5 kernel remains installed as a GRUB recovery option.
