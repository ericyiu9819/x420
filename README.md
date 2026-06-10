# x420

TCP-only 自用代理工程脚本。

核心方案：

```text
VLESS + REALITY + Vision over TCP/443
```

特点：

- 单协议、单出口，不使用 UDP。
- 不使用 selector/urltest/fallback，减少冗余和抖动。
- 服务端只保留一个 Xray inbound。
- 默认启用原生 BBR + fq + tcp_mtu_probing。
- 默认只放行 `22/tcp` 和 `443/tcp`。
- 支持生成 Shadowrocket URI 和二维码 SVG。

## 全功能一键安装

安装两个核心功能：

```text
1. x420 TCP REALITY 代理
2. Lean BBR Assist 网络优化工具与最小 BBR/fq 参数
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)
```

如果要同时安装自定义 BBR 内核，显式打开：

```bash
INSTALL_KERNEL=1 bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)
```

注意：自定义内核安装会修改 `/boot` 和 GRUB，但不会自动重启。确认云厂商控制台/GRUB 回滚能力后再重启。

只安装 Lean BBR Assist，不安装代理：

```bash
INSTALL_X420=0 bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)
```

带 iperf3 探测并应用 Lean BBR 参数：

```bash
LEAN_PROBE_HOST=speedtest.milkywan.fr LEAN_PROBE_PORT=9200 \
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-all.sh)
```

## 仅安装代理

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh)
```

可选：

```bash
REALITY_SERVER_NAME=www.microsoft.com \
REALITY_TARGET_DOMAIN=www.microsoft.com \
NODE_LABEL=my-node \
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install.sh)
```

安装后查看：

```bash
cat /root/x420-shadowrocket.uri
ls -l /root/x420-shadowrocket.svg
cat /root/x420-client.env
```

## 本地使用脚本

生成服务端配置：

```bash
./tcp-reality-single.sh gen-server > xray-server.json
```

生成 sing-box 客户端配置：

```bash
./tcp-reality-single.sh gen-client > sing-box-client.json
```

生成 Shadowrocket 链接：

```bash
./tcp-reality-single.sh gen-shadowrocket-uri
```

生成二维码：

```bash
./tcp-reality-single.sh gen-shadowrocket-qr shadowrocket.svg
```

任意导入链接转二维码：

```bash
./tcp-reality-single.sh gen-qr import.svg 'vless://...'
```

## 精简 BBR 内核与 Lean BBR Assist

本仓库新增一套面向 Debian/Ubuntu KVM VPS 的精简网络内核与运行时辅助算法。

已验证内核：

```text
6.12.93-bbrv1-kvm-netopt-ext4
```

内核目标：

```text
1. 精简 VPS 无关功能。
2. 保留 KVM/virtio/ext4/xfs 启动链。
3. 启用 BBR/fq/fq_codel。
4. 通过 .deb 包安装，保留旧内核回滚。
```

关键文件：

```text
install-all.sh
install-lean-bbr-kernel.sh
kernel-netopt/DELIVERY.md
kernel-netopt/config-fragments/kvm-netopt-x86_64.config
tools/net_adaptive_probe.py
reports/lean-bbr-assist-report-zh.md
reports/lean-bbr-assist-comparison-20260610.md
```

Lean BBR Assist 设计原则：

```text
1. 不重写 BBR。
2. 只做 P=1/2/4 低扰动探测。
3. 只有吞吐提升 >= 10% 且无重传，才接受更高并发。
4. 只写最小 BBR/fq sysctl 参数。
5. 异常或高重传时回到 P=1。
```

运行示例：

```bash
python3 tools/net_adaptive_probe.py --host <iperf3-server> --port 5201 --duration 8
```

应用最小内核参数：

```bash
sudo python3 tools/net_adaptive_probe.py \
  --host <iperf3-server> \
  --port 5201 \
  --duration 8 \
  --apply-kernel-tuning
```

## 安全提醒

- 安装脚本会在 VPS 本机生成 UUID、REALITY key 和 short_id。
- 不要把 `/root/x420-client.env` 公开。
- 建议安装后改为 SSH key 登录，并更换曾经在聊天中出现过的 root 密码。
- 自定义内核必须保留旧内核启动项，确认可回滚后再作为默认内核。
- 本项目仅用于自有 VPS 的合法远程访问、网络稳定性优化和自用加速。
