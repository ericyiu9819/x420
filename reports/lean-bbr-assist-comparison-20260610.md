# Lean BBR Assist Comparison

Date: 2026-06-10

Server: 203.88.127.40

Kernel:

```text
6.12.93-bbrv1-kvm-netopt-ext4
```

## Compared Profiles

Baseline:

```text
Controller: previous net-adaptive-probe
Sysctl file: /etc/sysctl.d/99-net-bbr-auto.conf
Behavior: broader tuning set, weaker rejection of retransmission-heavy samples
```

After:

```text
Controller: Lean BBR Assist
Sysctl file: /etc/sysctl.d/99-lean-bbr-assist.conf
Behavior: minimal BBR/fq profile, P=1/2/4 only, zero-retransmission preference
```

## Sysctl Difference

Baseline managed extra service-oriented parameters:

```text
somaxconn
tcp_max_syn_backlog
tcp_fastopen
tcp_fin_timeout
tcp_keepalive_*
```

Lean BBR Assist manages only:

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 87380 16777216
```

## Result Summary

MilkyWan upload:

```text
Baseline:
P=1 351.26 Mbps retrans=1
P=2 332.73 Mbps retrans=1
P=4  66.58 Mbps retrans=0

Lean:
P=1 311.42 Mbps retrans=0
P=2 532.32 Mbps retrans=45

Decision change:
Lean chooses P=1 because it is clean. It rejects P=2 despite higher throughput because retransmits appear.
```

MilkyWan download:

```text
Baseline:
P=1 231.34 Mbps retrans=5336
P=2 331.94 Mbps retrans=2944
P=4 497.72 Mbps retrans=24002

Lean:
P=1 299.63 Mbps retrans=3226
P=2 343.43 Mbps retrans=5288

Decision change:
Lean stays conservative because all candidates have retransmits.
```

HE:

```text
Both baseline and after runs show public-node instability and zero-throughput samples.
Lean was patched during testing so that high-retransmission outliers are not selected.
```

## Engineering Conclusion

Lean BBR Assist is not trying to maximize a single public iperf number. It optimizes for stable, low-redundancy operation:

```text
1. Fewer sysctl knobs.
2. Fewer probe states.
3. Lower risk of selecting noisy high-throughput samples.
4. Clearer rollback.
5. Better alignment with the new custom kernel's built-in BBR/fq behavior.
```

The main visible change is decision quality, not raw peak speed. The algorithm now refuses to treat high retransmission as success.

## Files

Baseline:

```text
reports/baseline-20260610-144735/
```

After:

```text
reports/after-lean-20260610-145215/
```
