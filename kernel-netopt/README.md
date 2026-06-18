# x420 VPS BBR Kernel

This directory contains the current x420 custom kernel package set.

Version:

```text
6.18.35-vps-bbr
```

Target environment:

```text
KVM + Debian/Ubuntu + x86_64 + TCP proxy/web traffic
```

The kernel was built from the existing Debian/Ubuntu-style configuration and keeps the normal VPS boot path intact. The important networking options are enabled:

```text
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
```

Packages:

```text
kernel-netopt/packages/linux-image-6.18.35-vps-bbr_6.18.35-1_amd64.deb
kernel-netopt/packages/linux-headers-6.18.35-vps-bbr_6.18.35-1_amd64.deb
kernel-netopt/packages/linux-libc-dev_6.18.35-1_amd64.deb
kernel-netopt/packages/SHA256SUMS
```

Install:

```bash
INSTALL_KERNEL=1 bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)
```

Or install only the kernel:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-x-kernel.sh)
```

The installer does not reboot automatically. Reboot only after confirming the provider console or GRUB rollback path is available.

After reboot:

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing
tc qdisc show
```

Expected:

```text
6.18.35-vps-bbr
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_mtu_probing = 1
```

Rollback:

```text
1. Select the old distribution kernel from GRUB advanced options.
2. Remove /etc/sysctl.d/99-vps-bbr.conf and run sysctl --system.
3. Remove linux-image-6.18.35-vps-bbr and linux-headers-6.18.35-vps-bbr.
4. Run update-grub.
```

Runtime controller:

```bash
sudo install -m 0755 tools/physical_limit_controller.py /usr/local/sbin/x420-limit
x420-limit discover --url 'https://nbg1-speed.hetzner.com/100MB.bin' --rtt-host nbg1-speed.hetzner.com
```
