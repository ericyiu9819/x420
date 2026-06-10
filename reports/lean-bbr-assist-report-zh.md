# Lean BBR Assist 新算法测试报告

日期：2026-06-10

服务器：203.88.127.40

## 1. 当前内核

```text
6.12.93-bbrv1-kvm-netopt-ext4
```

当前网络核心能力：

```text
TCP 拥塞控制：BBR
队列算法：fq
根分区：ext4
网卡：eth0 正常
```

## 2. 新算法目标

新算法名称：

```text
Lean BBR Assist
```

设计目标：

```text
高效率
低冗余
低风险
快收敛
贴近裸内核参数
```

它不重写 BBR 内核算法，而是在 BBR/fq 之上做轻量控制：

```text
BBR：负责单连接发送速率
fq：负责平滑发包
Lean BBR Assist：负责选择业务并发数和最小 sysctl 参数
```

## 3. 新算法规则

只测试 3 个并发档位：

```text
P=1
P=2
P=4
```

选择规则：

```text
默认使用 P=1
只有吞吐提升 >= 10% 且重传为 0，才升到更高并发
只要出现重传，就停止继续上探
如果结果异常，回到 P=1
```

## 4. 最小内核参数

新算法只管理下面这些参数：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 87380 16777216
```

不再主动管理这些冗余参数：

```text
tcp_fastopen
tcp_fin_timeout
tcp_keepalive_*
somaxconn
tcp_max_syn_backlog
```

## 5. 测试结果

### MilkyWan 节点

测试节点：

```text
speedtest.milkywan.fr:9200
平均延迟：约 141 ms
丢包：0%
```

上传测试：

```text
P=1：311.42 Mbps，重传 0
P=2：532.32 Mbps，重传 45
```

算法选择：

```text
推荐 P=1
```

原因：

```text
P=2 虽然速度更高，但出现 45 次重传。
新算法认为这不是稳定收益，所以拒绝 P=2。
```

下载测试：

```text
P=1：299.63 Mbps，重传 3226
P=2：343.43 Mbps，重传 5288
```

算法选择：

```text
推荐 P=1
```

原因：

```text
所有档位都有明显重传，因此选择最低扰动的 P=1。
```

### HE 节点

测试节点：

```text
iperf.he.net:5201
平均延迟：约 8.4 ms
丢包：0%
```

测试中发现公共节点返回不稳定，存在 0 Mbps 或高重传样本。

新算法处理方式：

```text
不追高异常吞吐
不选择高重传样本
异常时回到 P=1
```

## 6. 对比结论

旧逻辑的问题：

```text
可能把高吞吐但高重传的结果当成推荐值
参数管理偏多
不够贴近裸内核
```

新算法改进：

```text
减少 sysctl 参数
减少测试状态
减少无效并发
拒绝高重传结果
优先选择稳定点
```

## 7. 当前推荐

当前建议业务默认并发：

```text
P=1
```

允许业务在需要时短暂探测：

```text
P=2
```

不建议默认使用：

```text
P=4 或更高
```

## 8. 回滚方式

如果要回滚新算法参数：

```bash
rm -f /etc/sysctl.d/99-lean-bbr-assist.conf
sysctl --system
rm -f /var/lib/lean-bbr-assist/recommendation.json
```

## 9. 最终结论

```text
Lean BBR Assist 已经成功运行在新内核上。
它比旧方案更低冗余、更保守、更稳定。
它不追求带重传的峰值速度，而是优先选择可持续、低风险的传输状态。
```
