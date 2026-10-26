# x420 · 多 VPS 代理部署

VLESS + TCP + REALITY + XTLS Vision。一份脚本可在多台 VPS 重复使用，每台生成独立凭据；自动检测和筛选 REALITY 目标，导出客户端配置，提供测速、可恢复的网络参数优化和部署失败回滚。

## iPhone / Shadowrocket 快速安装

在 Debian / Ubuntu VPS 上执行：

```bash
curl --fail --show-error --location --proto '=https' https://raw.githubusercontent.com/ericyiu9819/x420/main/vps-proxy.sh -o vps-proxy.sh
sudo bash vps-proxy.sh install --client-profile shadowrocket --optimize
```

安装结束会打印 `vless://` 链接，复制到 Shadowrocket 导入。每台 VPS 执行相同命令即可；同台重跑保留已有节点凭据。请放行云安全组和主机防火墙 TCP 443。脚本不会自动删除旧代理；端口被占用时停止部署，请先备份并处理旧服务。

Shadowrocket 兼容模式固定官方 Xray **v26.6.27**，并使用新旧 Chrome 指纹校验 REALITY 连接。它是较旧核心的兼容性回退，缺少后续版本修复和新的握手限制；手机仍需实际联网验证。

支持新握手的客户端可选 modern 模式，固定官方 Xray **v26.10.21**：

```bash
sudo bash vps-proxy.sh install --client-profile modern --optimize
```

## 检查、配置和测速

```bash
sudo bash vps-proxy.sh check
sudo cat /var/lib/vps-proxy/clients/vless.txt
bash vps-proxy.sh self-test
bash vps-proxy.sh bench
```

VPS 上测速反映出口能力；本地通过代理测速才包含本地到 VPS 的路径，具体参数见完整说明。自动目标检测、BBR 和 Vision 均不能保证不被识别、永不封锁或本地速度达到 VPS 出口速度。

- [完整使用说明](README.zh-CN.md)：自动目标筛选、模式切换、导出、测速、优化与恢复。
- [验证记录与测试边界](验证说明.md)。
- [SHA256 校验文件](SHA256SUMS)：下载后可运行 `sha256sum -c SHA256SUMS` 校验对应文件。

仓库原有的 `install-vless-stack.sh` 保留供历史使用；本说明的安装入口为 `vps-proxy.sh`。旧脚本与新脚本使用不同服务和配置目录，不可在同一端口同时运行。

请勿将部署生成的私钥、节点链接、客户端配置或服务器密码提交到仓库。
