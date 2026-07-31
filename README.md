# X420 Proxy Kernel

Production-tested Debian amd64 kernel packages for TCP/UDP proxy VPS hosts.

## Recommended: Linux 6.18.41 LTS

The recommended build is `6.18.41-vps-proxy` with upstream BBR and FQ as
built-in defaults. It retains VirtIO, nftables TPROXY, BPF/XDP, io_uring,
kTLS, WireGuard and the cloud drivers needed by common KVM, Xen, Hyper-V and
VMware VPS platforms.

Package set:

- `packages/linux-image-6.18.41-vps-proxy_6.18.41-1_amd64.deb`
- `packages/linux-headers-6.18.41-vps-proxy_6.18.41-1_amd64.deb`
- `packages/linux-libc-dev_6.18.41-1_amd64.deb`

Verify:

```sh
shasum -a 256 -c SHA256SUMS
```

Install the runtime kernel package:

```sh
sudo dpkg -i packages/linux-image-6.18.41-vps-proxy_6.18.41-1_amd64.deb
sudo update-grub
```

Install headers only if DKMS or external kernel modules are needed.

The package was built, installed and twice reboot-tested on a Debian 12 amd64
KVM VPS with 1 vCPU and 1 GiB RAM. Xray, SSH, external ports 22/443 and the
BBR + FQ runtime profile remained healthy with zero failed systemd units.

Short public-network A/B samples against the previous 7.1.5 + EQS setup:

| Metric | 7.1.5 + EQS | 6.18.41 + FQ | Change |
|---|---:|---:|---:|
| Idle RTT average | 2.555 ms | 2.568 ms | +0.5% |
| 64 MB download | 655.5 Mbit/s | 756.8 Mbit/s | +15.5% |
| 32 MB upload | 296.6 Mbit/s | 636.2 Mbit/s | +114.5% |
| 128 MB loaded upload | 286.9 Mbit/s | 539.5 Mbit/s | +88.0% |
| Loaded RTT average | 2.613 ms | 3.223 ms | +23.3% |

These are directional public-network samples, not laboratory capacity
certification. See
[`vps-proxy-kernel/test-results/REPORT.md`](vps-proxy-kernel/test-results/REPORT.md)
for the complete result and health checks.

The verified booted kernel string is:

```text
Linux racknerd-7c62692 6.18.41-vps-proxy #1 SMP PREEMPT_DYNAMIC Thu Jul 30 14:14:47 EDT 2026 x86_64 GNU/Linux
```

Reproducible build configuration, deployment scripts and raw test output are
under [`vps-proxy-kernel/`](vps-proxy-kernel/).
