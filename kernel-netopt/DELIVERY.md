# 高性能精简 BBR 网络内核交付说明

日期：2026-06-10

## 已验证服务器

```text
203.88.127.40
```

## 已安装并验证的新内核

```text
6.12.93-bbrv1-kvm-netopt-ext4
```

## 内核目标

```text
1. 面向 Debian/Ubuntu KVM VPS。
2. 保留 ext4/xfs、virtio、TCP/IP、BBR、fq。
3. 裁剪桌面图形、声卡、蓝牙、Wi-Fi、WireGuard、NFS/CIFS/BTRFS/VFAT 等非必要能力。
4. 使用 .deb 包安装，不直接覆盖系统内核。
5. 保留发行版旧内核用于回滚。
```

## 当前运行状态

```text
TCP 拥塞控制：bbr
队列算法：fq
根分区：ext4
网卡：eth0 正常
BBR 模块：tcp_bbr.ko 已加载
旧内核：6.1.0-31-amd64 已保留
```

## 关键内核配置

```text
CONFIG_TCP_CONG_BBR=m
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=m
CONFIG_EXT4_FS=y
CONFIG_XFS_FS=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_HZ_1000=y
CONFIG_PREEMPT_DYNAMIC=y
# CONFIG_WIREGUARD is not set
# CONFIG_DRM is not set
# CONFIG_SOUND is not set
# CONFIG_BT is not set
# CONFIG_WIRELESS is not set
```

## 构建产物说明

实际 `.deb` 内核包体积较大，未直接提交到 GitHub。本仓库提交的是：

```text
1. 新内核配置说明。
2. Lean BBR Assist 新算法脚本。
3. 测试与对比报告。
```

本地/构建服务器上曾生成的包名：

```text
linux-image-6.12.93-bbrv1-kvm-netopt-ext4_6.12.93.bbrv1.2_amd64.deb
linux-headers-6.12.93-bbrv1-kvm-netopt-ext4_6.12.93.bbrv1.2_amd64.deb
```

## 回滚方式

从 GRUB 选择旧内核：

```text
Debian GNU/Linux, with Linux 6.1.0-31-amd64
```

回滚 BBR 参数：

```bash
rm -f /etc/sysctl.d/99-lean-bbr-assist.conf
sysctl --system
```

如需卸载新内核：

```bash
dpkg -l | grep '6.12.93-bbrv1-kvm-netopt-ext4'
apt remove linux-image-6.12.93-bbrv1-kvm-netopt-ext4 linux-headers-6.12.93-bbrv1-kvm-netopt-ext4
update-grub
```
