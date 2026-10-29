# shadowsocks-rust 服务端一键部署脚本（Debian 13）

在 Debian 13 服务器上部署 [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) 的 `ssserver`，只用 SS2022（Shadowsocks 2022 / SIP022）。

| 加密方式 | 密钥 | 多用户（EIH） |
|---|---|---|
| `2022-blake3-aes-128-gcm`（默认） | 16 字节 | 支持 |
| `2022-blake3-aes-256-gcm` | 32 字节 | 支持 |
| `2022-blake3-chacha20-poly1305` | 32 字节 | **不支持**，只能单用户 |

交互界面与流程沿用作者的 [WHStudio/xray-install-script-for-debian](https://github.com/WHStudio/xray-install-script-for-debian)。

## 快速开始

```bash
# 以 root 运行，进入中文交互菜单
bash <(curl -fsSL https://raw.githubusercontent.com/WHStudio/ssrust-install-script-for-debian/main/install.sh)
# 或先下载再运行
curl -fsSLo install.sh https://raw.githubusercontent.com/WHStudio/ssrust-install-script-for-debian/main/install.sh && bash install.sh
```

非交互示例：

```bash
# 单用户，默认 aes-128，随机端口
NONINTERACTIVE=1 bash install.sh install
# 多用户（EIH），aes-256，指定端口
NONINTERACTIVE=1 SS_METHOD=2022-blake3-aes-256-gcm SS_USERS=alice,bob SS_PORT=8388 bash install.sh install
```

## 命令

```
bash install.sh [install|update|reconfigure|info|uninstall] [--purge] [-y]
```

- `install`：安装。已安装时等同于重新配置，默认沿用现有加密方式、端口、用户和密钥。
- `update`：只更新二进制（校验 SHA256，配置不动）。新版本启动失败时自动回滚到旧二进制。
- `reconfigure`：重新配置加密方式、端口、用户。
- `info`：显示客户端配置（mihomo YAML 和 ss:// 链接）。
- `uninstall`：卸载，默认保留 `/etc/shadowsocks-rust`；加 `--purge` 会同时删除配置目录和 `shadowsocks` 用户。
- 不带参数运行进入菜单。已安装时可选择更新、重新配置、显示信息、卸载或退出。

## 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `SS_ACTION` | 指定操作，同上面的命令 | 菜单 |
| `NONINTERACTIVE` | 设为 1 时全部从环境变量读取，不提问（等同 `-y`） | 0 |
| `SS_VERSION` | 版本号。`latest` 表示通过 GitHub API 取最新稳定版 | `1.25.0` |
| `SS_LIBC` | `gnu` / `musl` | `gnu`；glibc < 2.39 时自动改用 `musl` 并提示 |
| `GITHUB_PROXY` | 下载前缀代理，如 `https://ghfast.top/` | 空 |
| `SS_METHOD` | 三种加密方式之一，见上表 | 沿用已有，否则 aes-128 |
| `SS_PORT` | 端口（TCP+UDP），会检查是否被占用 | 沿用已有，否则 4000–9999 随机 |
| `SS_USERS` | 逗号分隔的用户名 = 多用户 EIH；`single` = 单用户 | 沿用已有，否则单用户 |
| `KEEP_KEYS` | 重新配置时是否沿用已有密钥（1/0） | 交互时询问，非交互沿用 |
| `NODE_NAME` | mihomo 节点名，多用户时为 `<NODE_NAME>-<用户名>` | `ss-rust` |
| `SERVER_ADDRESS` | 客户端连接用的地址（IP 或域名） | 自动探测 |
| `DETECT_PUBLIC_IP` | 为 1 且 `SERVER_ADDRESS` 为空时，请求 api.ipify.org 探测公网 IP | 1 |
| `NFT_GUARD` | 加载 nftables 按 uid 拦截内网目标（第二层防护） | 1 |
| `PURGE` | 卸载时一并删除配置和用户（等同 `--purge`） | 0 |
| `SKIP_START` | 只写文件，不启动服务 | 0 |
| `FORCE_DOWNLOAD` | 版本相同也重新下载 | 0 |

非交互模式下指定 chacha20 加多个用户会直接报错。交互模式下选 chacha20 会说明原因，并自动改为单用户。

## 生成的服务端配置

- `/etc/shadowsocks-rust/config.json`（`root:shadowsocks 0640`），始终使用 `servers[]` 格式：
  - `server: "::"`，`mode: tcp_and_udp`，`timeout` 和 `udp_timeout` 均为 300，`udp_max_associations: 4096`；
  - `no_delay: true`，`keep_alive: 15`，日志 level 0，`runtime.mode: multi_thread`；
  - 密钥由 `ssservice genkey -m <method>` 生成。
  - 多用户时 `servers[].password` 是 iPSK，`servers[].users[]` 是每个用户的 `name` 和 uPSK。客户端密码为 `iPSK:uPSK`。
- **不配置** `manager_address`、ssmanager、`plugin`、`online_config`、`outbound_proxy`：没有回落，也没有外部控制。生成后会自检，出现这些字段就拒绝写入。
- 禁止通过代理访问内网、本机和保留地址，分两层：
  1. ACL `/etc/shadowsocks-rust/server.acl`：`[accept_all]` 加 `[outbound_block_list]`，包括 IPv4/IPv6 内网、回环、链路本地、组播和 `|localhost`。
  2. nftables 独立表 `inet ss_rust_guard`（`ss-rust-guard.service` 加载）：对 `meta skuid shadowsocks` 主动发起的、目标为上述地址的新连接执行 reject。已建立连接的回包放行。`/etc/resolv.conf` 中位于内网的 DNS 服务器的 53 端口单独放行。这一层兜底 DNS rebinding 等绕过 ACL 的情况。
  - ACL 中**没有**写 `::ffff:0:0/96`：ssserver 的双栈 UDP 出站会把 IPv4 目标映射成 `::ffff:a.b.c.d` 再匹配 ACL，写上会误杀所有 IPv4 UDP（实测）。映射地址实际发出的是 IPv4 包，由 nftables 的 IPv4 规则兜底。
- systemd 服务 `ss-rust.service`：
  - 以固定系统用户 `shadowsocks` 运行，`LimitNOFILE=65535`；
  - 加固项包括 `ProtectSystem=strict`、`ProtectProc=invisible`、`ProcSubset=pid`、`MemoryDenyWriteExecute`、`SystemCallFilter=@system-service ~@privileged @resources`、`RestrictAddressFamilies` 等。已在 Debian 13 的 systemd 257 下验证可以正常启动。
- 开启 NTP：已同步则跳过，否则在没有对时服务时安装 `systemd-timesyncd` 并执行 `timedatectl set-ntp true`；失败只告警。**SS2022 要求两端时间差不超过 30 秒**，客户端设备也要开启自动对时。
- 防火墙：脚本只提示需要放行的 TCP+UDP 端口，除了自己的 nft 表，不修改你的防火墙规则。nft 表加载失败只告警，不影响服务启动。
- 重新配置或更新后，如果服务启动失败，会自动恢复旧配置或旧二进制。

## 客户端输出

保存在 `/etc/shadowsocks-rust/client-mihomo.yaml`（0600），格式如下（多用户时每个用户一个节点，名称为 `ss-rust-<用户名>`，密码为 `"iPSK:uPSK"`）：

```yaml
proxies:
- name: ss-rust
  type: ss
  server: 203.0.113.10
  port: 6666
  cipher: 2022-blake3-aes-128-gcm
  password: password
  udp: true
```

不输出 `udp-over-tcp`。ss:// 分享链接（SIP002，由 `ssurl` 生成）保存在 `/etc/shadowsocks-rust/share-links.txt`（0600）。

## 下载与校验

- 下载 `shadowsocks-v<版本>.<arch>-unknown-linux-gnu.tar.xz`（arch 为 x86_64 或 aarch64），glibc 不足 2.39 时改用 `-musl`。
- 用官方 `.sha256` 文件校验（能访问 GitHub API 时，还会与 API 返回的 digest 比对），然后安装 `ssserver`、`ssservice`、`ssurl` 到 `/usr/local/bin`。

## 卸载

```bash
bash install.sh uninstall          # 停止并删除服务、二进制、nft 表，保留配置
bash install.sh uninstall --purge  # 同时删除 /etc/shadowsocks-rust 和 shadowsocks 用户
```

卸载会 `reset-failed` 两个单元，并删除 `inet ss_rust_guard` 表。

## 测试方法（test/）

测试只在本机回环上进行，不产生公网代理流量，不测速；默认配置不做任何放宽。

- 环境：Debian 13 rootfs，用 `systemd-nspawn --register=no --keep-unit --private-network -b` 启动。容器有独立的网络命名空间，只有 `lo`。
- `test/ct.sh`：在容器内以干净环境运行 `install.sh`。
- `test/loopback-test.sh`：
  - 校验 YAML 格式、文件权限和禁止字段，再用 `mihomo -t` 检查配置；
  - 在容器 `lo` 上添加 `198.51.100.1`（文档保留地址，不在屏蔽列表内）作为“公网”目标，经 mihomo 验证 TCP（HTTP 200）和 UDP（echo）可以转发；
  - 添加 `10.99.0.1` 作为内网目标，验证 `127.0.0.1`、`10.99.0.1`、`localhost`、`[::1]` 和 UDP 均被 ACL 拦截；
  - 以 `shadowsocks` 用户直接 curl，验证 nftables 层的拦截；
  - 检查正常流量期间日志里没有 WARN/ERROR。
- `test/pty_drive.py`、`udp_echo.py`、`udp_probe.py` 是辅助脚本。rootfs、mihomo 二进制和测试输出不入库（见 `.gitignore`）。

## 注意事项

- 有人尝试经代理访问内网地址时，ssserver 会记录 `blocked by ACL rules` 日志：TCP 为 ERROR，UDP 为 WARN。这是拦截生效的正常记录，不是故障。正常流量下日志没有 WARN/ERROR。
- 如果在共享宿主网络命名空间、权限受限的容器里运行（例如没有 `CAP_NET_ADMIN` 的 nspawn），nft 表可能加载失败（`netlink: cache initialization failed`）。此时只告警，ACL 仍然生效。
- 在容器内运行时会跳过 NTP 设置，时间由宿主机负责。
- 单用户切换到多用户时，原密码改作 iPSK，所有客户端都需要更新；更换加密方式同理。
