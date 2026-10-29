#!/usr/bin/env bash
# 仅回环测试（不产生任何公网代理流量，不测速）。
# 前提：用 systemd-nspawn --private-network -b 启动的 Debian 13 容器（独立网络命名空间，只有 lo），
#       容器内已用 install.sh 安装（SERVER_ADDRESS=127.0.0.1），ss-rust.service 运行中。
# 做法：在容器 lo 上加两个测试地址：
#   198.51.100.1（TEST-NET-2，文档保留地址，不在 ACL / nft 屏蔽列表内）→ 作为"公网"目标，验证 TCP/UDP 正常转发；
#   10.99.0.1（内网地址）→ 验证被屏蔽。两者都只存在于容器的私有命名空间里，流量不会离开容器。
#   这样测试的就是 install.sh 生成的生产配置本身，不需要任何测试专用的放行例外。
# 用法：sudo LEADER=<容器 systemd 的 PID> MIHOMO=/path/to/mihomo ROOTFS=/path/to/rootfs bash loopback-test.sh
set -Eeuo pipefail
: "${LEADER:?}" "${MIHOMO:?}" "${ROOTFS:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
PIDS=()
cleanup() {
  local p; for p in "${PIDS[@]}"; do kill "${p}" 2>/dev/null || true; done
  pkill -f -- "${WORK}" 2>/dev/null || true; pkill -f -- "udp_echo.py 9053" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
inct() { nsenter -t "${LEADER}" -a -- "$@"; }     # 容器内（mount/pid/net 全部命名空间）
innet() { nsenter -t "${LEADER}" -n -- "$@"; }    # 只进入容器的网络命名空间（使用宿主的 mihomo/python/curl）
ETC="${ROOTFS}/etc/shadowsocks-rust"
SINCE="$(inct date '+%Y-%m-%d %H:%M:%S')"
pass=0; fail=0
expect() { if [[ "$3" == "$2" ]]; then echo "  PASS  $1 → $3"; pass=$((pass+1)); else echo "  FAIL  $1 → $3（期望 $2）"; fail=$((fail+1)); fi; }

[[ "$(innet ip -br link | awk '{print $1}' | tr '\n' ' ')" == "lo " ]] || { echo "容器必须使用 --private-network（只有 lo）"; exit 1; }

echo "== 阶段 0：生成的文件"
re='^proxies:\n(- name: ss-rust(-[A-Za-z0-9_-]+)?\n  type: ss\n  server: [^\n]+\n  port: [0-9]+\n  cipher: 2022-blake3-[a-z0-9-]+\n  password: "[A-Za-z0-9+/=:]+"\n  udp: true\n)+$'
expect "client-mihomo.yaml 格式（块样式、字段顺序、password 加引号、无 udp-over-tcp）" yes \
  "$(python3 -c 'import re,sys; print("yes" if re.fullmatch(sys.argv[1], open(sys.argv[2]).read()) else "no")' "${re}" "${ETC}/client-mihomo.yaml")"
expect "client-mihomo.yaml 权限" 600 "$(stat -c %a "${ETC}/client-mihomo.yaml")"
expect "config.json 权限/属主" "640 root:shadowsocks" "$(inct stat -c '%a %U:%G' /etc/shadowsocks-rust/config.json)"
expect "config.json 无 manager/plugin/online_config/outbound_proxy" 0 \
  "$(grep -cE '"(manager_address|manager_port|plugin|online_config|outbound_proxy)"' "${ETC}/config.json" || true)"
expect "ss:// 链接数 = 节点数" "$(grep -c '^- name:' "${ETC}/client-mihomo.yaml")" "$(grep -c '^ss://' "${ETC}/share-links.txt")"
expect "ss-rust.service active" active "$(inct systemctl is-active ss-rust.service)"
expect "ss-rust-guard.service active（nft 表已加载）" active "$(inct systemctl is-active ss-rust-guard.service)"

# 测试地址与本地服务（仅容器私有命名空间）
innet ip addr replace 198.51.100.1/32 dev lo
innet ip addr replace 10.99.0.1/32 dev lo
mkdir -p "${WORK}/www"; echo ok > "${WORK}/www/index.html"
innet python3 -m http.server 9080 --bind 0.0.0.0 --directory "${WORK}/www" >/dev/null 2>&1 & PIDS+=($!)
innet python3 "${HERE}/udp_echo.py" 9053 & PIDS+=($!)

# mihomo：原样使用生成的 proxies，每个节点一个 socks 入口（只监听 127.0.0.1）
mapfile -t NODES < <(awk '/^- name: / { print $3 }' "${ETC}/client-mihomo.yaml")
{
  printf 'mode: rule\nlog-level: warning\nallow-lan: false\nbind-address: 127.0.0.1\nipv6: false\ngeo-auto-update: false\ndns: { enable: false }\n'
  cat "${ETC}/client-mihomo.yaml"
  printf 'listeners:\n'
  for i in "${!NODES[@]}"; do printf '  - {name: l%d, type: socks, listen: 127.0.0.1, port: %d, udp: true, proxy: %s}\n' "$i" $((35001 + i)) "${NODES[$i]}"; done
  printf 'rules:\n  - MATCH,DIRECT\n'
} > "${WORK}/client.yaml"
expect "mihomo -t 接受生成的配置" 0 "$("${MIHOMO}" -t -d "${WORK}" -f "${WORK}/client.yaml" >/dev/null 2>&1; echo $?)"
innet "${MIHOMO}" -d "${WORK}" -f "${WORK}/client.yaml" > "${WORK}/mihomo.log" 2>&1 & PIDS+=($!)
sleep 2
code() { innet curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@" || true; }

echo "== 阶段 A：正常转发（目标 198.51.100.1，生产配置）"
for i in "${!NODES[@]}"; do
  p=$((35001 + i)); n="${NODES[$i]}"
  expect "[$n] TCP http://198.51.100.1:9080" 200 "$(code --socks5 "127.0.0.1:${p}" http://198.51.100.1:9080/)"
  expect "[$n] UDP echo 198.51.100.1:9053" ECHO_OK "$(innet python3 "${HERE}/udp_probe.py" "${p}" 198.51.100.1 9053 || true)"
done
CLEAN_SINCE="$(inct date '+%Y-%m-%d %H:%M:%S')"
sleep 1
sl="$(inct journalctl -q -o cat --no-pager --since "${SINCE}" -u ss-rust.service 2>/dev/null || true)"
expect "正常流量阶段 ss-rust 日志无 WARN/ERROR/stream cipher" 0 "$(grep -ciE 'WARN|ERROR|stream cipher' <<< "${sl}" || true)"
expect "正常流量阶段 journalctl -p warning（ss-rust 相关单元）为空" 0 \
  "$(inct journalctl -q -o cat --no-pager --since "${SINCE}" -p warning -u ss-rust.service -u ss-rust-guard.service 2>/dev/null | wc -l)"

echo "== 阶段 B：屏蔽内网/本机目标（生产 ACL）"
p=35001; n="${NODES[0]}"
expect "[$n] TCP 127.0.0.1:9080 应被屏蔽" 000 "$(code --socks5 "127.0.0.1:${p}" http://127.0.0.1:9080/)"
expect "[$n] TCP 10.99.0.1:9080 应被屏蔽" 000 "$(code --socks5 "127.0.0.1:${p}" http://10.99.0.1:9080/)"
expect "[$n] TCP localhost:9080（域名）应被屏蔽" 000 "$(code --socks5-hostname "127.0.0.1:${p}" http://localhost:9080/)"
expect "[$n] TCP [::1]:9080 应被屏蔽" 000 "$(code --socks5-hostname "127.0.0.1:${p}" 'http://[::1]:9080/')"
expect "[$n] UDP 127.0.0.1:9053 应被屏蔽" NO_ECHO "$(innet python3 "${HERE}/udp_probe.py" "${p}" 127.0.0.1 9053 || true)"
expect "[$n] UDP 10.99.0.1:9053 应被屏蔽" NO_ECHO "$(innet python3 "${HERE}/udp_probe.py" "${p}" 10.99.0.1 9053 || true)"
echo "== 阶段 C：nftables 按 uid 拦截（绕过 ACL，直接以 shadowsocks 用户发起连接）"
asss() { inct setpriv --reuid=shadowsocks --regid=shadowsocks --clear-groups "$@"; }
expect "shadowsocks 用户直连 198.51.100.1:9080（对照）" 200 "$(asss curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://198.51.100.1:9080/ || true)"
expect "shadowsocks 用户直连 10.99.0.1:9080 应被 nft 拒绝" 000 "$(asss curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://10.99.0.1:9080/ || true)"
expect "shadowsocks 用户直连 127.0.0.1:9080 应被 nft 拒绝" 000 "$(asss curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:9080/ || true)"
expect "root 直连 10.99.0.1:9080 不受影响（只针对 shadowsocks 用户）" 200 "$(inct curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://10.99.0.1:9080/ || true)"
echo "  INFO  屏蔽阶段 ss-rust 日志（level 0）新增行："
inct journalctl -q -o cat --no-pager --since "${CLEAN_SINCE}" -u ss-rust.service | sed 's/^/        /' | head -8 || true
innet ip addr del 198.51.100.1/32 dev lo || true
innet ip addr del 10.99.0.1/32 dev lo || true
echo "mihomo 客户端日志（最后 3 行）："; tail -3 "${WORK}/mihomo.log"
echo "结果：PASS=${pass} FAIL=${fail}"
[[ "${fail}" -eq 0 ]]
