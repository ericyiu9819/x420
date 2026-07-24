# Linux 6.18.39 LTS + BBRQ 交付包

## 目标与边界

本交付包用于构建面向网络性能的 Linux 6.18.39 LTS 内核，并增加基于 BBR 的实验性拥塞控制算法 `bbrq`。

当前开发机运行的是 Apple Silicon macOS/XNU。BBR 属于 Linux TCP 栈，不能编入 XNU。因此本包提供 Linux 补丁、可复现构建、切换、回滚和 A/B 测试工具；不会替换当前 Mac 的内核。

当前目标机是 Debian 12 x86_64 KVM VPS：1 vCPU、2 GiB 内存、单队列
virtio_net，运行 Xray VLESS + REALITY。构建配置针对这一代理负载保留
16 MiB socket 缓冲上限、HZ=250 和动态抢占，并避免单核 busy-poll。

截至 2026-07-24，6.18.39 是 kernel.org 最新的 6.18 LTS 更新。源码包 SHA-256 已固定在构建脚本中。

## 已完成验证

- 补丁可应用到官方 Linux 6.18.39 源码；
- Kconfig 可解析，`CONFIG_TCP_CONG_BBRQ=m` 可选；
- `tcp_bbrq.c` 已由 Linux Kbuild + Clang 实际交叉编译为 ARM64 ELF 目标文件；
- 已在 Debian 12 x86_64 KVM VPS 上使用完整兼容配置构建
  `6.18.39-bbrq` 的 `bzImage` 和 3,971 个模块；
- `tcp_bbrq.ko`、`tcp_bbr.ko`、`virtio_net.ko` 和 `virtio_blk.ko`
  已完成链接、签名和 `depmod`，模块 `vermagic` 为
  `6.18.39-bbrq SMP preempt mod_unload modversions`；
- 原版 `bbr` 未被覆盖，运行时可在 `cubic`、`bbr`、`bbrq` 间切换；
- 完整二进制交付包通过远端与本地 SHA-256 一致性校验；
- 首次一次性启动测试后主机端口可达但 SSH 未返回协议 banner，因此启动
  与运行时性能验证仍记为**未确认**，需要通过 VPS 控制台获取启动日志或
  回退到旧内核后继续诊断。不能把“成功编译”表述为“已稳定上线”。

## 文件

- `0001-*.patch`：BBRQ 内核补丁；
- `DESIGN.md`：算法、参数和成功判据；
- `build-kernel.sh`：在 Linux x86_64/ARM64 主机上构建内核与模块；
- `activate-bbrq.sh`：临时启用，仅影响新建 TCP 连接；
- `rollback-bbrq.sh`：恢复之前的控制器和 qdisc；
- `benchmark-ab.sh`：对 CUBIC、BBR、BBRQ 做原始 A/B 采样；
- `network-performance.sysctl`：需评审后才持久化的保守网络参数。
- `BUILD-REPORT.md`：x86_64 构建、静态核验和首次启动测试记录。

## 构建

在 Linux 构建机安装发行版的内核构建依赖后运行：

```bash
chmod +x build-kernel.sh
BASE_CONFIG=/boot/config-$(uname -r) ./build-kernel.sh
```

交付物会放在 `artifacts/`。脚本不会自动写入 `/boot`，也不会修改引导器。

如目标机与构建机不同，必须显式提供目标机的 `.config`：

```bash
ARCH=arm64 BASE_CONFIG=/path/to/target.config ./build-kernel.sh
```

## 安装原则

使用发行版原生内核打包流程安装为“新增内核”，保留当前可启动内核和引导项。首次启动应通过控制台或带外管理进行。确认网卡、存储、根文件系统和 initramfs 正常后，才加载 `tcp_bbrq`。

临时启用：

```bash
sudo ./activate-bbrq.sh
```

回滚：

```bash
sudo ./rollback-bbrq.sh
```

## 性能验证

在另一台机器启动 `iperf3 -s`，目标机运行：

```bash
sudo ./benchmark-ab.sh <iperf3-server-ip> 30 4
```

至少重复五轮。吞吐量单独变高不代表算法更好；必须同时比较重传、负载下 RTT p95/p99、公平性和 CPU 成本。详见 `DESIGN.md`。

## 二进制交付

GitHub Release 附件：

`linux-6.18.39-bbrq-x86.tar.gz`

SHA-256：

`8f9b9f16a8252021799b95cb03203a3688a258e9e20841bc872bfdd23e3c3c45`

该附件是构建产物，不应提交到普通 Git 历史。首次启动必须具备 VPS
控制台或救援模式，并保留发行版旧内核作为持久默认回退项。
