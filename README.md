# x420

VLESS + TCP:443 + REALITY + xtls-rprx-vision 单线路安装脚本。

内核：BBR + fq。Xray 以 root 直听 443，出网 IPv4，无反代、无 Mux。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-vless-stack.sh)
```

或指定 dest：

```bash
curl -fsSL https://raw.githubusercontent.com/ericyiu9819/x420/main/install-vless-stack.sh -o install-vless-stack.sh
DEST=www.apple.com SNI=www.apple.com bash install-vless-stack.sh
```

Shadowrocket：导入脚本结束时打印的 `vless://` 链接；国内直连，关闭 Mux。
