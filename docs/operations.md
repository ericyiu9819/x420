# Operations

## Tuning logic

问题意图可以抽象为两层：

- 链路层：垃圾线路的问题通常是丢包、排队、抖动、晚高峰拥塞和 TCP 队头阻塞。
- 识别层：暴露面通常来自空站、默认页、错误响应、奇怪端口、证书不一致和未认证连接的代理特征。

本方案的约束是单 VPS 且只走 TCP，所以不做多跳调度和 UDP 主入口；核心收益来自单一 TCP 入口、正常 TLS 站点 fallback，以及避免自动切换造成的长连接断流。

## TCP behavior

纯 TCP 方案的稳定性取决于线路丢包和拥塞程度：

- 优点：没有 UDP 封锁问题，没有主备自动切换，SSH、WebSocket、下载等长连接更可预期。
- 代价：高丢包线路上 TCP 可能出现明显队头阻塞，网页表现为卡顿或吞吐下降。
- 建议：系统层开启 BBR，并避免在客户端上再配置频繁的自动节点切换。

## Fallback behavior

`443/tcp` 的未认证流量会被 Xray fallback 到 `127.0.0.1:8080` 的 Caddy 静态站点。验证重点：

- 浏览器打开 `https://DOMAIN/` 是正常网页。
- 错误 UUID 或普通 TLS 扫描不应看到代理错误页。
- 证书域名必须和访问域名一致。

## Client policy

客户端只有一个出口：`vless-tcp`。这会牺牲故障自动切换能力，但可以避免策略组切换导致已有 TCP 会话中断。

## Minimal acceptance checklist

- `curl -I https://DOMAIN/` 返回正常 HTTP 响应。
- `systemctl status caddy xray` 均为 running。
- VPS 防火墙允许 `443/tcp`。
- 客户端能通过 `vless-tcp` 打开网页。
