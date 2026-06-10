# High Performance KVM BBR Kernel Build Kit

This directory documents the Debian/Ubuntu KVM VPS kernel plan used for the verified `6.12.93-bbrv1-kvm-netopt-ext4` deployment.

## Tracks

```text
bbrv1: upstream Linux 6.12.y LTS with mainline TCP BBR.
bbrv3: experimental Google BBR v3 only when patch compatibility succeeds.
```

## Production Kernel Policy

The verified production path is BBRv1:

```text
CONFIG_TCP_CONG_BBR=m
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=m
CONFIG_HZ_1000=y
CONFIG_PREEMPT_DYNAMIC=y
```

The kernel is packaged as Debian `.deb` packages and installed without overwriting old kernels directly.

## VPS Compatibility

The ext4-compatible KVM profile keeps the boot-critical pieces built in:

```text
CONFIG_EXT4_FS=y
CONFIG_XFS_FS=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_ATA_PIIX=y
```

It removes VPS-unneeded pieces:

```text
# CONFIG_WIREGUARD is not set
# CONFIG_DRM is not set
# CONFIG_SOUND is not set
# CONFIG_BT is not set
# CONFIG_WIRELESS is not set
# CONFIG_BTRFS_FS is not set
# CONFIG_NFS_FS is not set
# CONFIG_CIFS is not set
# CONFIG_SMB_SERVER is not set
```

## Build Notes

The build host used kernel.org Linux `6.12.y`, produced Debian packages with `bindeb-pkg`, and verified that the generated image contained:

```text
/boot/vmlinuz-6.12.93-bbrv1-kvm-netopt-ext4
/lib/modules/6.12.93-bbrv1-kvm-netopt-ext4/kernel/net/ipv4/tcp_bbr.ko
/lib/modules/6.12.93-bbrv1-kvm-netopt-ext4/kernel/net/sched/sch_fq.ko
/lib/modules/6.12.93-bbrv1-kvm-netopt-ext4/kernel/net/sched/sch_fq_codel.ko
```

## Runtime Policy

Runtime tuning is intentionally minimal and delegated to Lean BBR Assist:

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 87380 16777216
```

## Rollback

Keep the distribution kernel in GRUB. On the verified server, rollback kernel remained:

```text
6.1.0-31-amd64
```

Rollback steps:

```bash
# Select old kernel in GRUB advanced options, then after boot:
rm -f /etc/sysctl.d/99-lean-bbr-assist.conf
sysctl --system
apt remove linux-image-6.12.93-bbrv1-kvm-netopt-ext4 linux-headers-6.12.93-bbrv1-kvm-netopt-ext4
update-grub
```
