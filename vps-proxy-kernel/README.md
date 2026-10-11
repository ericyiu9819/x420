# VPS Proxy Kernel

面向 Debian/Ubuntu VPS 网络代理负载的 Linux 6.18 LTS 内核配置与运行时调优。

默认选择：

- Linux 6.18.41 LTS；
- TCP 拥塞控制：BBR；
- 根队列规则：`fq`；
- 保留 VirtIO、Xen、Hyper-V、VMware 和常见云平台启动能力；
- 保留 nftables、eBPF/XDP、io_uring、kTLS、WireGuard；
- 不通过关闭内核安全保护换取跑分。

`fq + BBR` 面向代理服务器的高吞吐和低排队延迟。CAKE 更适合已知带宽瓶颈上的整形与公平共享，
但 CPU 开销更高，因此不作为 VPS 代理的默认根队列。

## 直接使用

在目标 VPS 上执行：

```bash
sudo ./scripts/install-tuning.sh
sudo systemctl reboot
```

重启后验证：

```bash
./scripts/verify.sh
```

这一步使用发行版现有内核；只要内核提供 BBR 和 `sch_fq`，无需先编译定制内核。

## 自适应队列脚本

安装后使用 `vps-queuectl`。它会读取默认出口、MTU、在线 CPU 数和 TX
队列数；`auto` 在 1–2 vCPU 或单队列 VPS 上选择 `efficient`：

```bash
# 只展示推导出的参数，不修改网络
sudo vps-queuectl plan --profile auto

# 应用并显示结果；安装服务默认执行这一条
sudo vps-queuectl apply --profile auto

# 查看 qdisc 统计
sudo vps-queuectl status

# 恢复首次应用前的拥塞控制、默认 qdisc 和根 qdisc 类型
sudo vps-queuectl rollback
```

可选配置包括 `latency`、`balanced` 和 `throughput`。只有已知实际出口瓶颈
速率时才使用 CAKE 整形，例如：

```bash
sudo vps-queuectl plan --profile shaped --rate 800mbit
sudo vps-queuectl apply --profile shaped --rate 800mbit
```

`efficient` 使用 `fq + BBR`、`quantum=2×FQ 链路调度单位` 和
`flow_limit=100`；在 MTU 1500 的 Ethernet/VirtIO 设备上，调度单位为
1514，最终 `quantum` 为 3028。它针对单核代理减少调度次数并限制单流排队；
脚本不擅自修改 RPS/XPS、ring size、网卡 offload 或中断亲和性。

## 构建定制内核

建议在与目标 VPS 同架构的 Debian/Ubuntu 构建机上运行：

```bash
sudo apt-get update
sudo apt-get install -y \
  bc binutils bison build-essential cpio dwarves fakeroot flex git \
  kmod libelf-dev libncurses-dev libssl-dev lz4 rsync zstd

./scripts/build-kernel.sh
```

脚本从 kernel.org 下载并校验 `v6.18.41` 官方发布包，以当前系统
`/boot/config-$(uname -r)` 为兼容性基线，再合并
[`kernel/config/vps-proxy.fragment`](kernel/config/vps-proxy.fragment)，最终生成 Debian 包。

可覆盖默认值：

```bash
KERNEL_VERSION=6.18.41 \
BASE_CONFIG=/boot/config-$(uname -r) \
JOBS=$(nproc) \
./scripts/build-kernel.sh
```

默认执行 `localmodconfig`，再重新启用本项目明确需要的云平台与网络功能。
如需保留基线配置中的全部通用模块，可设置 `TRIM_CONFIG=0`。

生成的包位于 `out/packages/`。安装 `linux-image` 与匹配的 `linux-headers` 包后重启，
不要删除云厂商提供的原内核，它是回滚入口。

## 设计边界

- 调优目标是常规 TCP/UDP 代理和透明 L4 代理，不假设 VPS 能控制物理 NIC。
- 不强制设置 RPS/XPS：虚拟 NIC 多队列拓扑由宿主机决定，错误的跨核 steering 可能更慢。
- 不固定 MTU、ring size 或中断合并参数：这些通常受云厂商限制。
- 不使用超大的静态连接跟踪表；如果业务启用 NAT，再按真实并发单独配置。
- `fq` 是发送侧队列，不会修复 VPS 上游已经形成的 bufferbloat。

## 卸载运行时调优

```bash
sudo ./scripts/uninstall-tuning.sh
sudo systemctl reboot
```

卸载脚本删除本项目安装的 sysctl 和 systemd 单元；重启会恢复发行版默认运行时参数。
