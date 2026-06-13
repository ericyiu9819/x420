# x: First-Principles TCP Efficiency Stack

## First Principle

`x` is the first-principles kernel and control algorithm for the x420 TCP
REALITY proxy path.

For a TCP proxy, network efficiency is not peak Mbps. It is:

```text
maximize useful delivered bytes per second
subject to bounded retransmission waste, bounded queueing delay, and bounded CPU cost
```

In formula form:

```text
maximize:   goodput
constraints:
  retrans_rate <= epsilon
  queue_growth <= beta
  cpu_used <= cap
  boot/runtime compatibility is preserved
```

For x defaults:

```text
upload epsilon   = 0.0010  # estimated retransmission rate <= 0.1%
download epsilon = 0.0005  # stricter receive-path stability threshold
upload beta      = 0.30    # RTT queue growth <= 30%
download beta    = 0.20    # download path should be more conservative
cap              = 80%     # CPU used <= 80%
```

## What This Changes

The old engineering rule was:

```text
reject any retransmission
```

The first-principles rule is:

```text
reject excessive retransmission waste
```

That matters because one retransmission in a long, high-throughput test is not
the same physical event as many retransmissions in a short test. The algorithm
must reason about rate, not just count.

## Kernel Restructure

The kernel should do only the things the kernel is uniquely good at:

```text
1. provide TCP congestion control
2. provide packet pacing
3. expose accurate TCP state
4. boot reliably on the VPS platform
5. avoid unnecessary driver and desktop stacks
```

Recommended production path:

```text
Linux 6.12.y LTS
BBRv1 built in
fq built in
HZ=1000
PREEMPT_DYNAMIC
KVM/virtio boot path built in
ext4/xfs built in
nftables/iptables compatibility as modules
```

Key config:

```text
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
CONFIG_HZ_1000=y
CONFIG_PREEMPT_DYNAMIC=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_BLK=y
CONFIG_EXT4_FS=y
CONFIG_XFS_FS=y
```

Do not put application policy into the kernel. For this x420 workload, the
kernel does not need WireGuard, Hysteria-specific assumptions, desktop graphics,
wireless, Bluetooth, sound, or broad storage stacks.

The concrete config fragment is:

```text
kernel-netopt/config-fragments/x-stable-kvm-x86_64.config
```

## Runtime Restructure

Runtime sysctl should only connect the workload to the kernel capabilities:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
```

Avoid folding service knobs into the efficiency algorithm:

```text
tcp_fastopen
tcp_fin_timeout
tcp_keepalive_*
somaxconn
tcp_max_syn_backlog
```

Those can be tuned for service policy later, but they are not the core path for
BBR/fq efficiency.

## Algorithm Restructure

The controller is a constrained optimizer over a tiny action space:

```text
upload actions: P = 1, 2, 4, 8
download actions: P = 1, 2, 4
objective: maximize goodput score
constraints: retrans_rate, queue_growth, cpu_idle
```

Derived metrics:

```text
estimated_segments = bytes_sent / MSS
retrans_rate = retransmits / estimated_segments
goodput = throughput * (1 - min(retrans_rate, 0.50))
queue_growth = (rtt_ms - min_rtt_ms) / min_rtt_ms
```

Acceptance:

```text
candidate is usable if:
  goodput > 0
  retrans_rate <= profile threshold
  queue_growth <= profile threshold
  cpu_idle >= 20%

candidate replaces best if:
  usable
  (candidate_goodput - best_goodput) / best_goodput >= 0.10
```

Stop conditions:

```text
throughput/goodput is zero
retrans_rate exceeds threshold
queue_growth exceeds threshold
CPU idle below threshold
goodput gain below 10%
```

## Why This Fits x420

x420 is a self-use TCP REALITY proxy. Its user-visible performance is dominated
by:

```text
retransmission waste
RTT inflation from queues
CPU saturation in user-space crypto/proxy code
route stability
```

So the correct optimization target is not:

```text
max synthetic iperf throughput
```

It is:

```text
max stable goodput without creating waste or latency debt
```

That is why `recommended_parallel=none` can be the correct answer. More
parallelism is accepted only when it produces clean useful throughput, and a
whole probe run is rejected when no candidate satisfies the hard constraints.

## Implemented Code Path

The implementation is in:

```text
tools/net_adaptive_probe.py
```

The important CLI thresholds are:

```text
--min-gain 0.10
--profile auto|upload|download
--max-retrans-rate
--max-queue-growth
--min-cpu-idle 20
--mss-bytes 1448
```

The rebuild guide is:

```text
kernel-netopt/REBUILD-X420-KERNEL.md
```
