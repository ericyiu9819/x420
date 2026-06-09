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

## 一键安装

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

## 安全提醒

- 安装脚本会在 VPS 本机生成 UUID、REALITY key 和 short_id。
- 不要把 `/root/x420-client.env` 公开。
- 建议安装后改为 SSH key 登录，并更换曾经在聊天中出现过的 root 密码。
- 本项目仅用于自有 VPS 的合法远程访问、网络稳定性优化和自用加速。
