# BBRQ 6.18.39 x86_64 构建报告

## 构建环境

- Debian 12 x86_64 KVM VPS；
- 1 vCPU、约 2 GiB 内存；
- 根磁盘使用 VirtIO，根文件系统为 XFS；
- 基础配置来自 Debian `6.1.0-10-amd64`，经 `olddefconfig` 迁移到
  Linux 6.18.39；
- 内核发布字符串：`6.18.39-bbrq`。

## 关键配置

```text
CONFIG_HZ_250=y
CONFIG_NET_RX_BUSY_POLL=y
CONFIG_NET_SCH_FQ=y
CONFIG_PREEMPT_DYNAMIC=y
CONFIG_TCP_CONG_BBR=m
CONFIG_TCP_CONG_BBRQ=m
CONFIG_VIRTIO_BLK=m
CONFIG_VIRTIO_NET=m
```

`NET_RX_BUSY_POLL` 表示保留能力；针对单 vCPU 目标机的建议运行时值仍为
0，避免忙轮询抢占代理进程 CPU。

## 构建结果

- `bzImage`：x86 启动镜像，版本 `6.18.39-bbrq`；
- `System.map` 和最终 `.config` 已包含在二进制交付包；
- 3,971 个 `.ko` 模块完成链接和构建时密钥签名；
- `modules.dep` 已由 `depmod` 生成；
- `tcp_bbrq.ko` 描述为
  `TCP BBRQ (queue-aware Bottleneck Bandwidth and RTT)`；
- `tcp_bbrq.ko` 暴露 `rtt_thresh`、`loss_thresh` 和
  `guard_duration` 三个模块参数；
- `tcp_bbrq.ko`、`tcp_bbr.ko`、`virtio_net.ko` 和
  `virtio_blk.ko` 的 `vermagic` 与内核匹配。

## 二进制校验

文件：

`linux-6.18.39-bbrq-x86.tar.gz`

大小：

`2,099,716,152 bytes`

SHA-256：

`8f9b9f16a8252021799b95cb03203a3688a258e9e20841bc872bfdd23e3c3c45`

远端生成值与下载后的本地计算值一致，且归档中已确认存在
`boot/bzImage` 与 `kernel/net/ipv4/tcp_bbrq.ko`。

## 首次启动测试状态

新内核以 GRUB 一次性启动项安装，旧 `6.1.0-10-amd64` 被保留为持久
默认项。新内核 initramfs 中确认包含：

- `virtio_blk`
- `virtio_pci`
- `virtio_net`
- `xfs`

触发一次性重启后，主机 ICMP、TCP/22 和 TCP/443 可达，但 SSH 未返回
协议 banner，无法远程确认实际运行内核、Xray 状态或 BBRQ 加载状态。
因此当前结论是：

- 编译、模块链接、签名、依赖和 initramfs 静态检查通过；
- 启动成功与运行时稳定性**尚未确认**；
- 在获得 VPS 网页控制台启动日志并完成回退/诊断前，不应设为生产默认
  内核，也不应宣称性能优于官方 BBR。
