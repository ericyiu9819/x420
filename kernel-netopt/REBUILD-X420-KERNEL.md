# Rebuild x-stable TCP REALITY Kernel

This kernel profile is part of `x`, the first-principles TCP efficiency stack
for x420.

This profile is inferred from the x420 proxy path:

```text
Xray VLESS + REALITY + Vision over TCP/443
```

The goal is stable network efficiency, not the highest single iperf number.
The kernel should provide a clean TCP pacing path and leave runtime policy small.

## Recommended Profile

Use a Linux 6.12.y LTS base and merge:

```text
kernel-netopt/config-fragments/x-stable-kvm-x86_64.config
```

Production choices:

```text
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
CONFIG_HZ_1000=y
CONFIG_PREEMPT_DYNAMIC=y
```

Compatibility choices:

```text
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_BLK=y
CONFIG_EXT4_FS=y
CONFIG_XFS_FS=y
CONFIG_NF_TABLES=m
CONFIG_IP_NF_IPTABLES=m
CONFIG_TUN=m
```

Do not add WireGuard/Hysteria-specific kernel work for the current x420 server
profile. The proxy script intentionally uses TCP only.

## Build On Debian/Ubuntu

Install build dependencies:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential bc bison flex libssl-dev libelf-dev dwarves \
  rsync git fakeroot debhelper pahole python3 kmod cpio xz-utils
```

Fetch and unpack the chosen 6.12.y kernel source:

```bash
mkdir -p ~/kernel-build
cd ~/kernel-build
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.93.tar.xz
tar -xf linux-6.12.93.tar.xz
cd linux-6.12.93
```

Start from the running distro config when building on a similar VPS:

```bash
cp /boot/config-$(uname -r) .config
```

Merge the x-stable fragment:

```bash
scripts/kconfig/merge_config.sh \
  .config \
  /path/to/x420/kernel-netopt/config-fragments/x-stable-kvm-x86_64.config

make olddefconfig
```

Set a unique local version:

```bash
scripts/config --set-str LOCALVERSION "-x"
make olddefconfig
```

Build Debian packages:

```bash
make -j"$(nproc)" bindeb-pkg
```

Install the generated image and headers:

```bash
cd ..
sudo dpkg -i linux-image-*-x_*.deb linux-headers-*-x_*.deb
sudo update-grub
```

## Runtime Sysctl

Keep runtime tuning minimal:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
```

## Validation After Reboot

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing
modinfo tcp_bbr || grep -w bbr /proc/sys/net/ipv4/tcp_available_congestion_control
tc qdisc show dev eth0
systemctl status xray --no-pager
ss -tlpen | grep ':443 '
```

Then run x420 probes:

```bash
tcp-reality-single observe
tcp-reality-single probe-direct
tcp-reality-single probe-proxy
```

## Rollback

Keep the distro kernel installed and visible in GRUB. If the custom kernel fails,
boot the old kernel from GRUB advanced options, then remove the custom packages:

```bash
sudo apt remove 'linux-image-*-x' 'linux-headers-*-x'
sudo update-grub
```
