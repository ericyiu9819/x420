# BBRQ 设计说明

BBRQ 是基于 Linux BBR v1 的实验性、队列感知拥塞控制算法。它没有修改原版 `bbr`，而是以 `bbrq` 注册为独立控制器，以便与 BBR、CUBIC 做同机 A/B 测试并快速回滚。

目标负载是单 vCPU、2 GiB 内存 KVM VPS 上的 Xray VLESS + REALITY
双向代理。该场景优先减少无效重传、排队和每连接内存开销，而不是追求
单条大流的最大缓存占用。

## 根本模型

BBR 的核心发送模型保持不变：

`pacing_rate = pacing_gain × max_delivery_rate`

`cwnd = cwnd_gain × max_delivery_rate × min_rtt`

其中，最大交付速率使用 10 个 packet-timed round 的窗口最大值，最小 RTT 使用 10 秒窗口最小值。

## BBRQ 增加的信号

队列信号：

`sample_rtt >= rtt_thresh × min_rtt`

默认 `rtt_thresh = 1280 / 1024 = 1.25`。连续两个 round 满足条件才触发，避免把一次 delayed ACK 或调度抖动误判为拥塞。

丢包信号：

`losses / delivered >= loss_thresh / 1000`

默认 `loss_thresh = 20 / 1000 = 2%`。

任一信号成立后，保护窗口默认持续两个 round：

- STARTUP：立即标记管道已满，进入 DRAIN；
- PROBE_BW：pacing gain 上限降为 0.90，cwnd gain 上限降为 1.5；
- 保护窗口结束后自动恢复原模型。

稳态探测周期从 BBR 的 `1.25 / 0.75 / 1×6` 调整为 `1.125 / 0.875 / 1×6`，周期平均增益仍为 1.0，但减少单次探测制造的队列峰值。

## 可调参数

模块加载后可从 `/sys/module/tcp_bbrq/parameters/` 调整：

- `rtt_thresh`：RTT 膨胀阈值，按 1024 缩放；
- `loss_thresh`：千分比丢包阈值；
- `guard_duration`：保护持续的 packet-timed rounds，范围 1–7。

这些参数必须通过代表性链路测试决定，不能把默认值视为对所有 WAN、蜂窝、Wi-Fi 或数据中心网络都最优。

## 成功判据

只有在相同链路、相同业务负载和至少五次重复测试下，同时满足以下条件，才能称为相对 BBR 的改进：

- 有效吞吐中位数不低于 BBR 的 98%；
- 负载下 RTT p95 明显下降；
- TCP 重传数和丢包率下降；
- 多流 Jain 公平指数不恶化；
- CPU/每 Gbit 开销没有显著上升；
- CUBIC/BBR 混合流量下不存在长期压制。

## 内核配置取舍

- 保留发行版配置和 virtio、存储、文件系统、安全机制，避免制作不可启动
  的极简内核；
- 使用 HZ=250 和动态抢占，避免单核 VPS 上 HZ=1000 带来的额外周期性
  开销；
- 保留 GRO、GSO、TSO、FQ、BQL、RPS/XPS；单队列单核环境不启用
  busy-poll；
- 保留 netfilter 能力，但当前没有规则时不引入 conntrack 路径；
- 关闭 DWARF/BTF 调试信息只为降低构建资源和产物体积，不关闭运行时
  安全缓解；
- socket 自适应缓冲上限保持 16 MiB，避免 64 MiB 上限在大量代理连接下
  放大内存压力。
