# VLESS 无冗余连接 · 完整脚本包

对应方案：`VLESS + tcp/raw + REALITY + xtls-rprx-vision`，单出口，mux 关闭，国内直连；服务端默认启用 BBR + fq。

## 文件

| 脚本 | 作用 |
| --- | --- |
| `vless-nr.sh` | 统一入口（推荐） |
| `install-server.sh` | VPS 一键安装 Xray、生成密钥、写配置、启动服务 |
| `gen-client.sh` | 用密钥文件生成客户端 JSON + 分享链接 |
| `gen-secrets.sh` | 本机只生成配置/密钥（不装服务） |
| `status-server.sh` | 查看服务与非敏感参数（含 BBR） |
| `enable-bbr.sh` | 单独启用 BBR + fq |
| `uninstall-server.sh` | 卸载 Xray（可选保留密钥） |
| `common.sh` | 公共函数（被其他脚本 source） |

## 服务端（VPS）

```bash
# 上传本目录到服务器后：
chmod +x *.sh
sudo ./install-server.sh
# 可选：
# sudo ./install-server.sh --sni www.microsoft.com --dest www.microsoft.com:443 --port 443
```

产物：
- `/usr/local/etc/xray/config.json`
- `/usr/local/etc/xray/vless-no-redundant.env`（权限 600）
- `/usr/local/etc/xray/share-link.txt`
- `./generated/client.json`

## 客户端

```bash
./gen-client.sh \
  --secrets /path/to/vless-no-redundant.env \
  --server YOUR_SERVER_IP \
  --out ./client.json \
  --link-out ./share-link.txt
```

然后用支持 Xray/VLESS Reality Vision 的客户端导入 `share-link.txt`，或：

```bash
xray run -c ./client.json
curl -x socks5h://127.0.0.1:10808 https://www.google.com -I
```

## 方案约束（脚本已写死）

- protocol = vless
- flow = xtls-rprx-vision
- mux.enabled = false
- 单 inbound / 单 proxy outbound / freedom 出口
- routing: private + geoip:cn + geosite:cn → direct

## 验收

1. `systemctl is-active xray` 为 active
2. 客户端配置里 `mux.enabled` 为 false
3. 国内站点不走代理
4. 不存在同目的并行热备隧道


## BBR

安装服务端时默认启用 BBR + `fq`（同路径 TCP 优化，不新增连接）。

```bash
sudo ./vless-nr.sh enable-bbr
sudo ./vless-nr.sh status
```

跳过：

```bash
sudo ./install-server.sh --skip-bbr
```
