# Linux 6.12.97 VPSFQ 内核构建报告

## 结果

- 发布名称：`6.12.97-vpsfq`
- Debian 包版本：`6.12.97-3`
- 架构：amd64
- 构建状态：成功
- 安装状态：未安装
- 启动项：未修改
- 服务器：未重启

## VPSFQ 的基本事实

VPSFQ 是 Linux 6.12.97 上游 `sch_fq` 的保守派生版本，不是新的 TCP
拥塞控制器。它保留上游 FQ 的逐流哈希、轮转公平性和基于
`sk_pacing_rate` 的内核 pacing，并以独立 qdisc 名称 `vpsfq` 注册。

这个内核将 `CONFIG_NET_SCH_VPSFQ=y` 和 `CONFIG_DEFAULT_VPSFQ=y` 设为
内建默认，同时将 BBR 设为默认 TCP 拥塞控制。原版 FQ、FQ-CoDel、CAKE
和 CUBIC 均保留，可用于回退和 A/B 测试。

## 面向小型 VPS 的参数

| 参数 | 上游 FQ | VPSFQ | 目标 |
|---|---:|---:|---|
| 总队列上限 | 10000 包 | 4096 包 | 限制排队内存 |
| 单流上限 | 100 包 | 64 包 | 限制单流突发 |
| 流表桶数 | 1024 | 512 | 改善小流量场景的缓存局部性 |
| 调度 quantum | 2 × MTU | 4 × MTU | 减少单核流切换开销 |
| 初始 quantum | 10 × MTU | 8 × MTU | 控制新流初始突发 |
| 定时器 slack | 10 微秒 | 20 微秒 | 减少 pacing 唤醒开销 |
| pacing horizon | 10 秒 | 2 秒 | 限制过远的未来排队 |

这些是工程假设，不等于已经证明的性能收益。安装前后的正确评估方法是与同版本
原版 FQ 做 A/B 测试，比较吞吐、CPU、重传、p95/p99 RTT 和队列丢包。

## 构建验收

- VPSFQ 单对象已成功编译为 x86-64 ELF。
- 最终 `vmlinux` 和包内 `System.map` 均包含：
  `vpsfq_enqueue`、`vpsfq_dequeue`、`vpsfq_qdisc_ops`、
  `vpsfq_module_init`。
- 最终配置通过专用验证脚本。
- 包内默认队列为 `vpsfq`，默认拥塞控制为 `bbr`。
- ENA 模块 `vermagic`：
  `6.12.97-vpsfq SMP preempt mod_unload modversions`。
- 包含 `vmlinuz`、`config` 和 `System.map`。
- 构建日志未发现编译错误。

## 软件包 SHA-256

- `linux-image-6.12.97-vpsfq_6.12.97-3_amd64.deb`：
  `25094e157dc4839a66e296de8ac282ffc693c8dd0ef9dfabebe7f5e15d3c5506`
- `linux-headers-6.12.97-vpsfq_6.12.97-3_amd64.deb`：
  `04bf4911cac45626f688bf64a1845405f870e2dbc3e7f933348e1b8ae91ec1f6`
- `linux-libc-dev_6.12.97-3_amd64.deb`：
  `94d879c92b684109a1f10b64091bc13270b1453500ff4d472df507fdde7abb83`

VPSFQ 不能突破服务商的端口限速、跨网拥塞或物理链路上限。它优化的是本机出口
排队、pacing 和单核调度效率。
