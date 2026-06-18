# X420 Generic Physical-Limit Controller

This controller is generic. It does not use parameters from any particular VPS.
It assumes the kernel base is:

```text
tcp_congestion_control=bbr
default_qdisc=fq
tcp_mtu_probing=1
```

The algorithm searches for the highest stable goodput:

```text
parallelism P = coarse path filling
rate cap R   = fine physical-limit tracking
```

## Install

```bash
sudo install -m 0755 tools/physical_limit_controller.py /usr/local/sbin/x420-limit
```

## Discover

Run a full generic search:

```bash
sudo x420-limit discover \
  --url 'https://nbg1-speed.hetzner.com/100MB.bin' \
  --rtt-host nbg1-speed.hetzner.com \
  --p-candidates 1,2,4,8,16
```

`discover` does:

```text
1. baseline RTT
2. coarse parallel search: P=1,2,4,8,16
3. stop when gain fades, score declines, or hard health limits trigger
4. rate knee search with fixed best P
5. write recommended P/R to /var/lib/x420/physical-limit-state.json
```

## Lock

Observe the saved P/R and perform one AIMD adjustment:

```bash
sudo x420-limit lock
```

Override state manually:

```bash
sudo x420-limit lock --seed-p 2 --seed-rate-mbps 30
```

## Micro Probe

Try a small `R * 1.03` probe and accept only if goodput improves without cost:

```bash
sudo x420-limit micro-probe
```

## Hard Boundaries

The controller backs off immediately on:

```text
TCP timeout
interface error
retrans_rate > 10%
CPU idle < 15%
HTTP 429 / target policer signal
RTT extra > 40ms and RTT growth > 80%
```

This matters because a physical-limit algorithm must distinguish:

```text
path limit     => usable signal
local CPU limit => reduce P/R
target policer => invalid test target
queue growth   => crossed the knee
```
