# VPS weak-line rescue gateway

这是一个单 VPS、纯 TCP 网关配置包，用现有成熟协议组合出“兼容优先、探测面收敛”的部署形态：

- `Xray VLESS over TLS` 监听 `443/tcp`，作为唯一代理入口。
- `Caddy` 监听 `127.0.0.1:8080`，承接未认证探测和普通 HTTPS fallback，返回真实网页内容。

设计意图：在只使用 TCP 的约束下，避免 UDP 可达性问题和主备切换导致的长连接断流，并通过正常 TLS/HTTP 行为降低误配置暴露面。它不是“绝对不可识别”的承诺。

## Files

- `server.env.example`：部署参数模板。
- `templates/`：Xray、Caddy 和客户端配置模板。
- `scripts/render-configs.sh`：把 `.env` 渲染为 `build/` 下的实际配置。
- `scripts/install-debian.sh`：Debian/Ubuntu 服务端安装脚本。
- `scripts/check-server.sh`：部署后的基础连通性检查。
- `docs/operations.md`：调参、验证和故障切换说明。

## Quick start

如果你要在一台干净 Debian/Ubuntu VPS 上直接做出线路，优先用完整一键脚本：

```bash
bash scripts/bootstrap-tcp-line.sh --domain example.com --email admin@example.com
```

脚本会自动安装 Xray、Caddy、acme.sh，签发证书，启用 BBR，并输出客户端链接与 sing-box 配置：

```text
/etc/rescue-gateway/client-links.txt
/etc/rescue-gateway/client-sing-box.json
```

运行前确保域名已经解析到 VPS，并且 `80/tcp`、`443/tcp` 可访问。

## Template workflow

在本目录准备参数：

```bash
cp server.env.example .env
${EDITOR:-vi} .env
./scripts/render-configs.sh .env
```

把整个目录上传到 VPS 后，以 root 执行：

```bash
./scripts/install-debian.sh .env
```

安装完成后，客户端使用 `build/client-sing-box.json` 中的 `vless-tcp`。

## Required inputs

- 一个解析到 VPS 的域名。
- 该域名的 TLS 证书和私钥，或允许安装脚本通过 Caddy/ACME 获取证书后再填入路径。
- 一个 UUID，作为 VLESS 用户身份。

## Port model

- `443/tcp`：Xray VLESS TLS fallback。

未认证或普通浏览器流量会 fallback 到本机 Caddy 站点；代理流量由 Xray 处理。
