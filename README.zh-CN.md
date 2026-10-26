# 多 VPS 通用代理部署脚本

每台 VPS 独立部署 Xray：VLESS + RAW/TCP + REALITY + XTLS Vision。首次安装生成独立 UUID、X25519 密钥和 shortId；同台重跑保留凭据。modern 模式默认固定 Xray v26.10.21；Shadowrocket 兼容模式固定较旧官方 v26.6.27，避免重跑时无意升级。

## 快速部署

将 `vps-proxy.sh` 上传到每台 VPS，执行同一条命令：

```bash
sudo bash vps-proxy.sh install --optimize
```

不再需要手工填写 REALITY 目标域名。首次部署自动检测公网 IPv4、筛选目标站、生成独立凭据和客户端配置；名称默认使用主机名。可以另外加 `--name VPS-A`。

需要 Debian/Ubuntu、systemd、amd64 或 arm64；建议 Debian 12/13、Ubuntu 22.04/24.04。Python 3 不存在时自动通过 apt 安装；其他依赖按需安装。Xray 固定版本二进制从 XTLS 官方 GitHub Release 下载，通过同一 Release 的 SHA256 摘要核验。该校验验证下载完整性，不是独立来源的数字签名认证。

默认监听 `0.0.0.0:443`。**仍需要放行云安全组和主机防火墙 TCP 443；脚本不修改现有防火墙。** 其他服务占用端口时会停止并提示，不会将其关闭。可用 `--port 8443` 等参数改端口，但应留意 Xray 对非 443 端口的提示。

NAT、域名入口等情况可手动指定：

```bash
sudo bash vps-proxy.sh install --name VPS-A --server 你的公网IP或域名 --optimize
```

IPv6 入口（示例地址必须替换）：

```bash
sudo bash vps-proxy.sh install --server '2001:db8::123' --listen '::' --name VPS-v6 --optimize
```

`::` 是否同时接受 IPv4 取决于主机双栈设置；默认 IPv4 监听不提供 IPv6 接入。NAT 场景假设公网端口与监听端口相同，不同端口映射需要自行调整客户端入口端口。自动公网地址检测目前优先 IPv4，只有 IPv6 时显式指定 `--server`。

## Shadowrocket / iPhone 兼容模式

如果使用 Shadowrocket（包括本次报告问题的 iPhone 2.2.92），可部署明确的兼容模式：

```bash
sudo bash vps-proxy.sh install --client-profile shadowrocket --optimize
```

已部署节点切换模式：

```bash
sudo bash vps-proxy.sh install --client-profile shadowrocket
```

该模式选择官方 v26.6.27，保留现有 UUID、REALITY 密钥、shortId、SNI 和端口，并在修改线上文件前使用普通 Chrome 与旧 Chrome 120 指纹分别完成临时 REALITY 令牌请求。修改核心前会备份旧二进制与配置，失败会尝试恢复。模式会写入状态，普通重跑沿用该模式与版本。

原因是默认 v26.10.21 使用的 REALITY 实现要求特定 X25519MLKEM768 ClientHello；导入链接里的 `fp=chrome` 在不同客户端中不一定生成同一套握手。同版本 Xray 自测成功，不能证明 Shadowrocket 一定能用。Shadowrocket 能显示端口延迟，也不代表 REALITY 认证通过。

**这是使用较旧官方核心的兼容性回退。** 较旧核心不包含后续版本的全部修复和新握手限制；不能声称抗探测效果与新版本完全相同。支持新握手的客户端优先使用 modern 模式。脚本的新旧指纹验证不是直接运行 iPhone Shadowrocket，手机仍需实际验证。本次实际用户已确认：iPhone Shadowrocket 2.2.92 在切换兼容模式后可以访问；其他客户端版本仍需分别验证。

返回默认新核心：

```bash
sudo bash vps-proxy.sh install --client-profile modern
```

`--client-profile shadowrocket` 当前只验证 v26.6.27；与其他显式 `--version` 组合会拒绝部署，避免出现“标签称兼容、实际核心不同”。兼容说明会随客户端配置导出为 `client-compatibility.json`。

版本依据：

- v26.10.21 绑定的 REALITY 源码：https://raw.githubusercontent.com/XTLS/REALITY/83f621788ca8/tls.go
- 同类 Shadowrocket 报告：https://github.com/XTLS/Xray-core/issues/6482

## 自动目标站筛选

只检测内置的 18 个公开域名，最多 6 并发，不扫描互联网地址段。内置域名是候选种子，不表示永久可用、适合每个地区或互不共享 CDN。每台 VPS 在部署当时独立测量，结果可能相同，也可能不同。

筛选步骤：

1. 解析目标域名；排除本机地址、私网、回环、链路本地和 Fake-IP 等非公网地址。每个域名最多检测一个 IPv4 和一个 IPv6。
2. 对每个候选 IP 连续检测两次证书与域名匹配、TLS 1.3 和 h2 协商，记录 TCP/完整 TLS 握手耗时及两次差值。失败地址不参与排序。
3. 默认通过 RIPEstat 查询入口和候选 IP 的 ASN：优先已确认同 ASN 的地址，再对已知共享边缘网络降低优先级，最后比较“握手中位数 + 两次差值”。ASN 未知会如实记录，不等于没有 CDN；已知边缘 ASN 清单不完整。排序是本脚本的启发式策略，不是官方抗探测评分。
4. 使用实际安装的 Xray 核心检查域名及固定 IP 两种配置；自动排除产生 REALITY 目标警告或配置错误的候选。
5. 对排名最高的最多 3 个候选，依次启动临时的本机 Xray 客户端和服务端，验证一次经过 REALITY 的本地随机令牌请求；成功即选定，失败尝试下一个。临时服务只监听 `127.0.0.1`，结束后清理，不开放公网测速端口，不把外部网站下载作为额外依赖。临时校验仅允许访问该随机本地 HTTP 端口，部署配置仍保留私网阻断规则。
6. 将选中域名作为 SNI，将已验证 IP 固定为服务端 REALITY `target`，避免后续 DNS 轮换让选中的 ASN/IP 与实际连接地址不一致。客户端继续使用域名 SNI，不使用 IP 替换 SNI。

结果保存到 `/var/lib/vps-proxy/target-selection.json`，包含每个候选的地址、检测样本、ASN、排除原因和选择依据，不包含 UUID 或服务端密钥。全部失败则写入 `/var/lib/vps-proxy/target-scan-failed.json`，停止部署；不会修改正在运行的服务配置。

内核/运行时、目标可达性与 ASN 服务状态会影响耗时，通常需要几十秒到数分钟。ASN 查询不可用时降级为已获取的兼容性与时延数据；TLS 或真实代理校验失败不会伪装为成功。RIPEstat 会收到被查询的公网入口和候选 IP；不想使用该服务时：

```bash
sudo bash vps-proxy.sh install --no-asn --optimize
```

ASN 查询以 `--server` 入口地址作为来源参考。若该入口本身是 CDN、第三方转发或与 VPS 实际网络不同，ASN 关系不能代表机器所在网络，需结合报告判断。

### 只检测，不部署

```bash
bash vps-proxy.sh scan-targets --server 你的公网IP --output target-scan.json
```

已部署时自动使用 `/opt/vps-proxy/xray`；没有可用核心时只做 TLS/网络检测并明确标记，不能把这个结果视为真实 REALITY 校验成功。也可用 `--xray /路径/xray` 指定本机核心。正式安装总是使用下载并校验过的核心执行完整筛选。

### 自定义候选与手动覆盖

想优先检测机房附近或同 ASN 的站点，可以提供自己的候选列表（每行一个域名，允许 `#` 注释，最多 64 个；替换内置列表）：

```bash
sudo bash vps-proxy.sh install --candidates-file targets.txt --optimize
```

仍可完全手动指定目标站：

```bash
sudo bash vps-proxy.sh install --sni 你的目标站域名 --optimize
```

手动模式进行证书/TLS 1.3/h2 检查及最终配置验证，但不会自动换站；核心提示会显示出来，由使用者决定是否继续使用该目标。`--sni` 是目标站域名，不是你的 VPS 域名，不能解析到本机入口。不必为 VPS 入口申请证书。

### 已部署节点重新筛选

普通重跑保留原 SNI、固定目标 IP 和密钥，并重新检测已固定地址，不会因为一时延迟差异换站。主动重新筛选：

```bash
sudo bash vps-proxy.sh install --reselect-target
# 或使用自己的候选列表
sudo bash vps-proxy.sh install --reselect-target --candidates-file targets.txt
```

重新筛选保留 UUID、私钥与 shortId，但目标域名可能变化。**服务会重启；应重新导入生成的客户端配置，因为客户端 SNI 可能改变。** 已固定目标 IP 后，如果站点改 IP 或撤回原地址，也需重新筛选或手动指定域名刷新解析；脚本不会在后台自动换站。

## 获取客户端配置

安装成功后，文件位于：

```text
/var/lib/vps-proxy/clients/
├── vless.txt          # VLESS 导入链接
├── xray-client.json   # Xray 客户端完整配置，SOCKS 127.0.0.1:10808
├── mihomo.yaml        # Mihomo 最小完整配置，混合代理 127.0.0.1:7890
├── node-info.json     # 节点连接参数，不包含服务器私钥
└── client-compatibility.json # 模式、核心版本与验证范围
```

例如使用有 root 登录权限的账号，在本地下载：

```bash
scp -r root@你的VPS地址:/var/lib/vps-proxy/clients ./VPS-A-clients
```

目录及文件默认仅 root 可读；不能直接 root 登录时通过 sudo 管理的安全方式传出。不要为了下载将整个状态目录改为公开可读。

- 将 `vless.txt` 中链接导入支持 REALITY + Vision 的客户端。
- Xray JSON 使用当前 `password` 字段承载 REALITY 客户端密钥；Mihomo 使用 `public-key`；VLESS 链接使用 `pbk`。
- Mihomo 配置使用 JSON 语法保存为 `.yaml`（JSON 是 YAML 子集），可作为独立配置导入；合并进现有配置时只提取节点条目，并加入原策略组，不要直接覆盖已有规则。
- 两种完整配置都是最小代理配置，默认经过代理；没有预置国内分流、TUN、DNS 规则或自动选路。可在现有客户端中导入节点并继续使用原分流。
- 主隧道使用 TCP；模板关闭客户端 UDP，适合网页和支持 TCP 回退的视频。强制依赖 UDP 的应用不属于此模板支持范围。
- 多台 VPS 的节点可统一导入客户端。视频组按持续吞吐选节点，网页组按连接质量选择。脚本不会把多 VPS 带宽叠加，也不会在公网托管订阅。

客户端文件包含接入凭据，请私下保存；即使 REALITY 客户端参数名叫公钥，也不应公开整套节点参数。服务端私钥只存于受保护的服务端状态/配置及备份中，不写入客户端导出。

同一台机器重复执行 `install`，未传入的入口、端口、SNI、名称、版本会沿用原值，密钥保持不变。不要将 `/etc/vps-proxy` 从已部署机器克隆到其他 VPS；只复制脚本即可获得独立凭据。

重新导出或修改入口名称：

```bash
sudo bash vps-proxy.sh export
sudo bash vps-proxy.sh install --name 新名称 --server 新的公网入口
```

改变已部署配置会重启本脚本服务，现有连接可能断开。

## 测速：分清 VPS 出口与本地端到端

脚本用 HTTPS/HTTP 1.1 下载，分别进行单连接和 4 并发测试，不额外开放测速端口。默认每个连接下载 32 MiB，完整一轮约 160 MiB，有时限；会消耗相关 VPS 流量额度。默认测速站可能限速或不可达，结果还受测速站路径影响，可换成你控制的足够大的 HTTPS 文件交叉验证。

在 VPS 上测它的外网下载能力：

```bash
bash vps-proxy.sh bench --output vps-direct.json
```

把同一脚本放到本地 Mac/Linux，先启动客户端，再测实际代理路径：

```bash
# 使用导出的 Xray JSON 时，SOCKS 默认端口为 10808
bash vps-proxy.sh bench \
  --proxy socks5h://127.0.0.1:10808 \
  --output local-proxy.json

# 使用导出的 Mihomo 配置时，可使用混合端口 7890
bash vps-proxy.sh bench --proxy socks5h://127.0.0.1:7890
```

`bench` 需要本地 Bash、Python 3、curl，不需要 root。Windows 可使用实际能访问客户端代理端口的 WSL 环境；WSL 与 Windows 的 localhost 是否互通取决于网络模式，必要时指定宿主机地址并配置代理监听权限。也可以用本地其他测速工具。

自定义测速：

```bash
bash vps-proxy.sh bench \
  --url 'https://你的测速域名/大文件.bin' \
  --streams 4 --seconds 30 \
  --proxy socks5h://127.0.0.1:10808 \
  --output custom-test.json
```

报告记录每条连接 HTTP 状态、下载字节、连接及首字节耗时、总耗时、是否时限截断；并发吞吐按总有效字节除以整组墙钟时间计算。环境代理变量不会覆盖显式测量路径。HTTP 错误、空下载和失败连接会标记并返回失败；达到时限且已有有效 HTTP 200 下载时，会以“部分下载”统计。

这些是下载测试，不是纯线路容量或双向测试，也不直接测丢包。小文件、服务端限速、缓存和 CDN 都会影响结果。建议在相近时间使用相同 URL，对不同节点进行对比，并在晚高峰复测；不要只凭低延迟或单个测速站选节点。`check` 提供主机 TCP 状态辅助诊断。

## 性能优化与恢复

安装命令加 `--optimize` 即可自动执行，也可以单独运行：

```bash
sudo bash vps-proxy.sh optimize
sudo bash vps-proxy.sh restore-tuning
```

优化范围：

- 检测内核 BBR 支持，支持时将系统默认 TCP 拥塞控制设为 BBR，默认队列设为 fq。
- 保留 TCP 接收缓冲区自动调节，黑洞探测后启用 TCP MTU probing。
- 根据内存将收发缓冲上限至少设为 4 MiB 或 16 MiB；不降低已有更大的上限，不把每条连接初始缓冲设为这个最大值。
- systemd 服务文件句柄限制为 65536。

主机 TCP 参数影响其他服务的新 TCP 连接。脚本不修改网卡 MTU、不替换内核、不重启网络、不强行更换现有网卡队列，也不关闭 IPv6。`default_qdisc=fq` 不等于已将现有网卡队列替换为 fq；可用 `tc qdisc show` 查看实际队列。BBR 不保证一定比原算法快，按优化前后测量决定是否保留。

原值保存于 `/var/lib/vps-proxy/sysctl-before.json`，持久化配置为 `/etc/sysctl.d/90-vps-proxy.conf`。已经有未恢复的优化记录时不覆盖；重跑安装带 `--optimize` 会提示已有记录，代理部署仍可成功。先恢复，再优化可建立新的基线。

优化步骤失败会尝试恢复原值；部分恢复失败时保留备份并报错。安装本身已经成功而优化失败时，不撤销代理部署。`restore-tuning` 恢复原先记录的运行时值，并移除本脚本的 sysctl 文件；其他系统管理工具或更靠后的 sysctl 文件仍可能在重启时覆盖参数，恢复期间不要同时用其他工具改同一批参数。

## 检查、升级和备份

```bash
sudo bash vps-proxy.sh check
sudo systemctl status vps-proxy --no-pager
sudo journalctl -u vps-proxy -n 80 --no-pager
bash vps-proxy.sh self-test
```

安装会先用下载的 Xray 核心检查服务端与客户端配置，再启用服务。服务使用独立非特权账号，只授予绑定低端口能力；默认阻止代理访问常见私网、回环及链路本地地址，不提供内网访问功能。备份存放于 `/var/lib/vps-proxy/backups/`，包含敏感配置，权限受限；重复部署会增加备份，请按需管理磁盘空间。

下载成功只表示二进制已校验；配置检查和本机端口监听成功不代表公网安全组已放行。必须从客户端验证。

固定到另一官方版本时：

```bash
sudo bash vps-proxy.sh install --version v26.10.21
```

将版本号替换为你已核验兼容的版本。安装失败会尝试恢复之前的二进制、配置和服务启停状态；系统依赖安装和新建服务账号不会被撤销。首次安装失败不会启动残缺服务。不要把脚本“失败回滚”理解为任意版本的一键历史恢复。

## 实际边界

REALITY 与 Vision 能兼顾 TCP 兼容、低开销和部分抗探测需求，但不保证无法识别、不封 IP、绕过线路限速或跑满 VPS 标称端口。自动筛选只覆盖有限候选集，不能证明目标站对 GFW 无特征，也不保证找到互联网范围内的最佳站点。目标站主要参与 REALITY 连接建立，不是视频下载出口；换目标站不等于改善本地到 VPS 的跨境吞吐。没有来自你的本地网络的测试，就不能对实际跨境速度或 GFW 环境下的稳定性作结论。

参考：

- https://xtls.github.io/en/config/transports/reality.html
- https://xtls.github.io/en/config/outbounds/vless.html
- https://github.com/XTLS/Xray-core/releases
- https://docs.kernel.org/networking/ip-sysctl.html

自动筛选的 ASN 数据来源说明：https://stat.ripe.net/docs/data-api/api-endpoints/network-info
