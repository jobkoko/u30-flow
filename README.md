# U30 Flow

A lightweight, native macOS menu bar monitor for U30 Air / compatible mu300-linux OpenWrt installations.

原生 macOS 状态栏工具，显示订阅余量、当天订阅用量增量、路由器实时上下行，以及外网响应。无需 SwiftBar 或额外的 Mac 后台运行时。

示意数据（并非真实账号或运行截图）：

```text
       ↓1.25M/s ↑85K/s
今 125M · 余 80G · 180ms
```

两行同色、加粗，宽度随文字自动收紧。数值按 1000 自动换算 B / K / M / G / T。

## 支持范围

- macOS 13 或更新版本；需 Xcode Command Line Tools、Python 3。
- Apple Silicon 可本地编译；构建脚本也支持在 Intel Mac 上编译本机架构。
- 路由端需要 OpenWrt/procd、Dropbear、公钥认证、`curl`、`awk`、`sha256sum` 及常用 BusyBox 工具。
- 订阅服务器须支持 HTTPS HEAD，并返回含 upload、download、total 的 `subscription-userinfo` 响应头。不提供这类数据的订阅不能凭空算出剩余量。
- 读取订阅地址支持两种方式：mu300 的简单单 provider 配置，或单独的 root-only URL 文件。复杂 YAML/多 provider 不会自动猜测。

这是源码项目。仓库不包含任何已配对密钥、账号、订阅地址、流量账单、主机公钥或真实设备配置。复制应用到另一台 Mac 不会自动获得路由器访问权。

## 1. 构建 Mac 应用

```sh
python3 scripts/build.py
# 可选：同时安装到当前用户的 Applications 文件夹
python3 scripts/build.py --install
```

构建结果在 `build/U30 Flow.app`。本地构建采用临时签名，未做 Developer ID 公证。不要关闭 Gatekeeper 或其他系统安全保护来运行来源不明的二进制；可审阅源码后自行构建。

## 2. 创建专用只读密钥

在 Mac 终端执行。若同名密钥已经存在，请保留并核对，不要直接覆盖：

```sh
mkdir -p "$HOME/Library/Application Support/U30 Flow"
chmod 700 "$HOME/Library/Application Support/U30 Flow"
ssh-keygen -t ed25519 -N '' -C u30-flow-readonly \
  -f "$HOME/Library/Application Support/U30 Flow/monitor_ed25519"
```

无口令密钥用于后台连接。服务端会把这把**新建的专用密钥**限制为固定的只读命令；不要复用管理员的普通 SSH 密钥。

## 3. 安装路由端

先使用正常的管理员 SSH 登录方式核验路由器主机指纹，确保记录在 Mac 的 `~/.ssh/known_hosts` 中。不要盲目信任 `ssh-keyscan` 的输出。后续将下列地址替换成自己的路由器地址；示例地址只是占位。

```sh
ROUTER_HOST=192.168.8.1
ssh "root@$ROUTER_HOST" 'umask 077; mkdir -p /root/u30-flow-setup; chmod 700 /root/u30-flow-setup'
scp router/* "root@$ROUTER_HOST:/root/u30-flow-setup/"
scp "$HOME/Library/Application Support/U30 Flow/monitor_ed25519.pub" \
  "root@$ROUTER_HOST:/root/u30-flow-setup/monitor.pub"
```

只有公钥上传路由器，私钥留在 Mac。不同 OpenSSH/Dropbear 组合可能需要给 `scp` 加 `-O`。

选择实际的单 provider 配置路径：

```sh
ssh "root@$ROUTER_HOST" \
  'sh /root/u30-flow-setup/install.sh --public-key /root/u30-flow-setup/monitor.pub --profile /etc/mu300/vpn/profiles/example/config.yaml'
```

也可以先在路由器上创建仅 root 可读、只含一行 HTTPS 订阅地址的文件，再把最后一个选项改成 `--subscription-url-file /root/subscription.url`。不要把订阅地址粘贴到公开 Issue、Shell 命令参数、仓库或日志中。

安装会保留原有管理员密钥。遇到未知旧安装或同一把密钥已有其他授权时会拒绝，避免误改。它只启用自己的 `u30-monitor` 服务，不重启拨号、Wi-Fi 或代理，也不增加监听端口。

按需编辑路由器 `/etc/u30-monitor/config`，格式见 `router/config.example`。修改后重启 `u30-monitor` 服务即可。`UTC_OFFSET` 为固定计费时区偏移，默认 UTC+08:00，不自动跟随夏令时；Mac 会使用路由端报告的偏移显示日期。

## 4. 配置 Mac 连接

把已核验的 SSH 主机公钥记录放到应用自己的 `known_hosts` 文件中。例如默认 SSH 端口：

```sh
ssh-keygen -F "$ROUTER_HOST" -f "$HOME/.ssh/known_hosts" | \
  sed '/^#/d' > "$HOME/Library/Application Support/U30 Flow/known_hosts"
chmod 600 "$HOME/Library/Application Support/U30 Flow/known_hosts"
```

自定义端口应匹配 `known_hosts` 中的 `[主机]:端口` 记录。应用保持严格的主机公钥验证；指纹变更需用户重新核验，不会自动跳过。

打开应用 → **连接设置…**，填写路由器地址、SSH 用户名和端口。也可参考 `config.example.json` 在应用数据目录创建 `config.json`。此文件是本机配置，不要提交到仓库。配对完成后，点击菜单可选开启“登录 Mac 时自动启动”；若系统要求批准，请在系统设置中处理。

## 数据口径

| 项目 | 含义 | 默认周期 |
|---|---|---|
| 今 / 订阅余量 | 订阅服务器累计账单的差值，包含其他设备使用相同订阅的消耗 | 5 分钟 |
| 上下行 | 指定蜂窝接口的实时速率，包含路由器全部设备与直连流量 | 3 秒 |
| 路由器响应 | Mac 到路由器的 ICMP 往返时间 | 30 秒 |
| 外网响应 | 绑定路由器所在接口、经路由器 DNS 访问检测地址的 HTTPS 总耗时 | 30 秒 |

- 第一天无法补算安装前的订阅消耗；菜单会显示记录开始时间。
- 机场可能延迟记账或采用倍率。本工具是近似观察值，不是结算账单。
- 漏过零点、切换订阅或账单计数重置时，会标记记录不完整，避免把昨天混入今天。
- 路由器持续开机时，Mac 休眠或退出应用不影响路由端记账；路由器停机期间的数据不能补采。
- 外网响应包含连接/TLS 建立时间，不等同于纯节点 Ping；不做下载测速，也不逐个测速订阅节点。
- 外网检测会产生少量计费流量。检测目标是公共静态连通性地址，不携带订阅凭证。

## 隐私与权限

应用不保存路由器管理员密码或订阅链接。专用 SSH 密钥只能运行 `u30-status` / `u30-stream`，禁止 shell、任意命令、端口转发、代理转发及 PTY。应用停止或异常退出后，SSH 连接会随之清理。

路由端数据位于仅 root 可读的 `/etc/u30-monitor`，临时请求位于 `/run/u30-monitor`。Mac 配对密钥、主机公钥和本机缓存位于当前用户的应用数据目录。没有统计遥测上传；但订阅服务商及用于连通性检测的服务仍能看到请求来源。

完整边界与发布注意事项见 [SECURITY.md](SECURITY.md)。

## 卸载与测试

路由器执行 `sh /root/u30-flow-setup/uninstall.sh`，只删除本工具的授权条目与服务，保留配置/历史以便恢复，不还原覆盖其他管理员密钥。

退出 Mac 应用、关闭其登录启动后可删除应用。本机应用数据目录包含私钥，备份或删除时请自行保管，不要公开。

```sh
python3 -m unittest discover -s tests -v
for file in router/*.sh router/*.init; do sh -n "$file"; done
python3 scripts/check_publication.py
```

安装测试仅操作临时目录，不会改动开发机器或真实路由器的 SSH 配置。CI 构建不安装/启动应用，不访问真实订阅。

MIT License. This project does not bundle vendor firmware or third-party proxy engines.
