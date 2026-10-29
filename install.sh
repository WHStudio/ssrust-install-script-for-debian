#!/usr/bin/env bash
# shadowsocks-rust (ssserver) 服务端一键部署脚本（Debian 13）
# SS2022：2022-blake3-aes-128-gcm（默认）/ 2022-blake3-aes-256-gcm / 2022-blake3-chacha20-poly1305
# 单用户或多用户（EIH，仅 AES 系列）；ACL + nftables（按 uid）禁止访问内网/本机；
# 不配置 manager / plugin / online_config / outbound_proxy（无回落、无外部控制）。
# 交互界面与流程参考 WHStudio/xray-install-script-for-debian。详见 README.zh_CN.md。

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"

# ── 可通过环境变量覆盖的参数 ────────────────────────────────────────────────
SS_ACTION="${SS_ACTION:-}"                # install | update | reconfigure | info | uninstall
NONINTERACTIVE="${NONINTERACTIVE:-0}"     # 1 = 全部从环境变量读取，不提问
SS_VERSION="${SS_VERSION:-1.25.0}"        # 固定版本；latest = 通过 GitHub API 取最新稳定版
SS_LIBC="${SS_LIBC:-}"                    # gnu | musl；留空 = gnu（glibc < 2.39 时自动改用 musl）
GITHUB_PROXY="${GITHUB_PROXY:-}"          # 下载前缀代理，如 https://ghfast.top/
SS_METHOD="${SS_METHOD:-}"                # 加密方式；留空 = 沿用已有，否则 2022-blake3-aes-128-gcm
SS_PORT="${SS_PORT:-}"                    # 留空 = 沿用已有，否则随机 4000-9999
SS_USERS="${SS_USERS:-}"                  # 逗号分隔用户名 = 多用户（EIH）；single = 单用户；留空 = 沿用已有/单用户
NODE_NAME="${NODE_NAME:-ss-rust}"         # mihomo 节点名（多用户为 <NODE_NAME>-<用户名>）
SERVER_ADDRESS="${SERVER_ADDRESS:-}"      # 客户端连接用的地址（IP 或域名）
DETECT_PUBLIC_IP="${DETECT_PUBLIC_IP:-1}" # 1 = SERVER_ADDRESS 为空时请求 api.ipify.org 探测
NFT_GUARD="${NFT_GUARD:-1}"               # 1 = 加载 nftables 按 uid 拦截内网目标（纵深防御）
KEEP_KEYS="${KEEP_KEYS:-}"                # 1/0：重新配置时沿用已有密钥
PURGE="${PURGE:-0}"                       # 卸载时 1 = 同时删除配置与 shadowsocks 用户
SKIP_START="${SKIP_START:-0}"             # 1 = 只写文件不启动服务
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"     # 1 = 版本相同也重新下载
SS_API_BASE="${SS_API_BASE:-https://api.github.com/repos/shadowsocks/shadowsocks-rust}"
SS_DOWNLOAD_BASE="${SS_DOWNLOAD_BASE:-https://github.com/shadowsocks/shadowsocks-rust/releases/download}"

# ── 路径 ───────────────────────────────────────────────────────────────────
readonly BIN_DIR="/usr/local/bin"
readonly SS_BIN="${BIN_DIR}/ssserver"
readonly SS_ETC="/etc/shadowsocks-rust"
readonly SS_CONFIG="${SS_ETC}/config.json"
readonly SS_ACL="${SS_ETC}/server.acl"
readonly NFT_FILE="${SS_ETC}/guard.nft"
readonly CLIENT_YAML="${SS_ETC}/client-mihomo.yaml"
readonly LINKS_FILE="${SS_ETC}/share-links.txt"
readonly SS_UNIT="/etc/systemd/system/ss-rust.service"
readonly NFT_UNIT="/etc/systemd/system/ss-rust-guard.service"
readonly SS_USER="shadowsocks"
readonly NFT_TABLE="ss_rust_guard"
readonly METHODS="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
readonly DEFAULT_METHOD="2022-blake3-aes-128-gcm"
readonly GLIBC_MIN="2.39"
# 不允许出现在服务端配置中的字段（无回落、无外部控制）
readonly FORBIDDEN_KEYS='["manager_address","manager_port","plugin","plugin_opts","plugin_args","plugin_mode","online_config","outbound_proxy"]'

TEMP_DIR=""
INTERACTIVE=1
USE_SYSTEMD=1
REPLY=""

# ── UI ─────────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''
fi
readonly C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN
readonly LINE="${C_DIM}────────────────────────────────────────────────────────${C_RESET}"

banner() {
  printf '\n%s%s' "${C_CYAN}" "${C_BOLD}"
  cat <<'EOF'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║          shadowsocks-rust  服务端管理脚本            ║
  ║        SS2022 (blake3)  ·  单用户 / 多用户 EIH       ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
EOF
  printf '%s\n' "${C_RESET}"
}

section() { printf '\n%s\n  %s●%s %s%s%s\n%s\n' "${LINE}" "${C_BLUE}" "${C_RESET}" "${C_BOLD}" "$1" "${C_RESET}" "${LINE}" >&2; }
info() { printf '  %s▸%s %s\n' "${C_CYAN}" "${C_RESET}" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn() { printf '  %s!%s %s%s%s\n' "${C_YELLOW}" "${C_RESET}" "${C_YELLOW}" "$*" "${C_RESET}" >&2; }
err()  { printf '  %s✘%s %s%s%s\n' "${C_RED}" "${C_RESET}" "${C_RED}" "$*" "${C_RESET}" >&2; }
die()  { err "$*"; exit 1; }

menu_item() {
  if [[ -n "${3:-}" ]]; then
    printf '     %s%s%s) %s  %s%s%s\n' "${C_CYAN}${C_BOLD}" "$1" "${C_RESET}" "$2" "${C_DIM}" "$3" "${C_RESET}" >&2
  else
    printf '     %s%s%s) %s\n' "${C_CYAN}${C_BOLD}" "$1" "${C_RESET}" "$2" >&2
  fi
}

# ask "提示" [默认值] -> REPLY
ask() {
  local prompt="$1" def="${2:-}"
  if [[ "${INTERACTIVE}" -ne 1 ]]; then REPLY="${def}"; return; fi
  if [[ -n "${def}" ]]; then
    printf '  %s?%s %s %s[默认 %s]%s：' "${C_MAGENTA}" "${C_RESET}" "${prompt}" "${C_DIM}" "${def}" "${C_RESET}" >&2
  else
    printf '  %s?%s %s：' "${C_MAGENTA}" "${C_RESET}" "${prompt}" >&2
  fi
  IFS= read -r REPLY || REPLY=""
  REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
  REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
  [[ -n "${REPLY}" ]] || REPLY="${def}"
}

# yes_no "提示" 默认(1/0) -> 返回 0 表示是
yes_no() {
  local prompt="$1" def="$2" hint
  if [[ "${def}" == 1 ]]; then hint="Y/n"; else hint="y/N"; fi
  if [[ "${INTERACTIVE}" -ne 1 ]]; then [[ "${def}" == 1 ]]; return; fi
  while true; do
    printf '  %s?%s %s %s[%s]%s：' "${C_MAGENTA}" "${C_RESET}" "${prompt}" "${C_DIM}" "${hint}" "${C_RESET}" >&2
    IFS= read -r REPLY || REPLY=""
    case "${REPLY}" in
      "") [[ "${def}" == 1 ]]; return ;;
      [Yy]|[Yy][Ee][Ss]|是) return 0 ;;
      [Nn]|[Nn][Oo]|否) return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

cleanup() { if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then rm -rf -- "${TEMP_DIR}"; fi; }
trap cleanup EXIT
trap 'err "脚本在第 ${LINENO} 行执行失败（命令：${BASH_COMMAND}）"; exit 1' ERR

usage() {
  cat <<EOF
用法：bash install.sh [install|update|reconfigure|info|uninstall] [--purge] [-y]

  install       安装（已安装时等同重新配置，默认沿用现有端口/用户/密钥）
  update        仅更新 shadowsocks-rust 二进制（校验 SHA256，保留配置）
  reconfigure   重新配置（加密方式、端口、用户）
  info          显示客户端配置（mihomo YAML 与 ss:// 链接）
  uninstall     卸载（默认保留 ${SS_ETC}；加 --purge 一并删除）
  -y            非交互模式（等同 NONINTERACTIVE=1）

不带参数运行进入交互菜单。全部环境变量见 README.zh_CN.md。
EOF
}

# ── 通用工具 ───────────────────────────────────────────────────────────────
is_true() { [[ "${1:-0}" =~ ^(1|y|Y|yes|YES|true|TRUE|on)$ ]]; }
proxy_url() { printf '%s%s\n' "${GITHUB_PROXY}" "$1"; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_ipv4() {
  local ip="$1" o; local -a octets
  [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "${ip}"
  for o in "${octets[@]}"; do ((10#${o} <= 255)) || return 1; done
}
is_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }
valid_method() { [[ " ${METHODS} " == *" $1 "* ]]; }
key_len() { case "$1" in 2022-blake3-aes-128-gcm) echo 24 ;; *) echo 44 ;; esac; }   # base64 长度：16 字节 / 32 字节
valid_key() { [[ "$2" =~ ^[A-Za-z0-9+/]+=*$ && ${#2} -eq $(key_len "$1") ]]; }
supports_eih() { [[ "$1" == 2022-blake3-aes-* ]]; }

port_in_use() {
  # 返回 0 = 端口（TCP 或 UDP）已被非 ssserver 进程占用
  local port="$1" out
  command -v ss >/dev/null 2>&1 || return 1
  out="$(ss -Hlntup "sport = :${port}" 2>/dev/null || true)"
  [[ -n "${out}" && "${out}" != *'"ssserver"'* ]]
}
random_port() {
  local p i
  for ((i = 0; i < 200; i++)); do
    p=$((4000 + RANDOM % 6000))
    command -v ss >/dev/null 2>&1 && [[ -n "$(ss -Hlntu "sport = :${p}" 2>/dev/null || true)" ]] && continue
    echo "${p}"; return
  done
  die "无法在 4000-9999 中找到空闲端口，请用 SS_PORT 指定"
}

installed_version() {
  [[ -x "${SS_BIN}" ]] || return 1
  "${SS_BIN}" --version 2>/dev/null | awk '{ print $2; exit }'
}
normalize_version() {
  local v="${1//[[:space:]]/}"; v="${v#v}"
  [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式无效：$1（应形如 1.25.0 或 latest）"
  printf '%s\n' "${v}"
}
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# ── 环境检查与依赖 ─────────────────────────────────────────────────────────
preflight() {
  section "环境检查"
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本"
  [[ -r /etc/os-release ]] || die "无法识别当前操作系统"
  local os_id os_ver arch
  os_id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
  os_ver="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
  [[ "${os_id}" == "debian" ]] || die "此脚本仅支持 Debian（检测到：${os_id:-未知}）"
  [[ "${os_ver}" == "13" ]] || warn "此脚本面向 Debian 13，当前为 Debian ${os_ver:-未知}，继续执行但未经测试"
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${arch}" in
    amd64|x86_64) TRIPLE_ARCH="x86_64" ;;
    arm64|aarch64) TRIPLE_ARCH="aarch64" ;;
    *) die "不支持的架构：${arch}（仅支持 amd64 / arm64）" ;;
  esac
  ok "系统：${os_id} ${os_ver:-?} / ${arch}"
  command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd"
  if [[ ! -d /run/systemd/system ]]; then
    warn "systemd 未作为 init 运行（容器/chroot？），将只写入文件不启动服务"
    USE_SYSTEMD=0; SKIP_START=1
  fi
}

ensure_deps() {
  local -a need=(ca-certificates curl xz-utils jq iproute2 nftables)
  local -a missing=()
  local p
  for p in "${need[@]}"; do
    dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "install ok installed" || missing+=("${p}")
  done
  if ((${#missing[@]} > 0)); then
    info "正在安装依赖：${missing[*]}"
    local i
    for i in 1 2 3; do
      DEBIAN_FRONTEND=noninteractive apt-get update -qq && break
      ((i < 3)) || die "apt-get update 失败，请检查软件源"
      warn "apt-get update 失败，5 秒后重试（${i}/3）"; sleep 5
    done
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
    ok "依赖安装完成"
  else
    ok "依赖已就绪"
  fi
}

prompt_github_proxy() {
  [[ "${INTERACTIVE}" -eq 1 && -z "${GITHUB_PROXY}" ]] || return 0
  section "GitHub 代理"
  info "访问 GitHub 较慢时可启用下载代理（无论是否使用代理，都会校验 SHA256）"
  printf '\n' >&2
  menu_item "0" "不使用代理（直连）" "[默认，推荐]"
  menu_item "1" "https://ghfast.top/"
  menu_item "2" "https://gh-proxy.com/"
  printf '\n' >&2
  while true; do
    ask "请输入选项 [0-2]" "0"
    case "${REPLY}" in
      0) GITHUB_PROXY=""; ok "直连 GitHub"; return ;;
      1) GITHUB_PROXY="https://ghfast.top/"; break ;;
      2) GITHUB_PROXY="https://gh-proxy.com/"; break ;;
      *) warn "选项无效，请重新输入" ;;
    esac
  done
  ok "已启用代理：${GITHUB_PROXY}"
}

# ── 下载与校验 ─────────────────────────────────────────────────────────────
choose_libc() {
  # 默认 gnu；glibc < 2.39（v1.25.0 gnu 包实测需要 GLIBC_2.39）时改用静态 musl 包
  local g
  g="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{ print $2 }' || true)"
  if [[ -z "${SS_LIBC}" ]]; then
    if [[ -n "${g}" ]] && ver_ge "${g}" "${GLIBC_MIN}"; then SS_LIBC=gnu
    else
      SS_LIBC=musl
      warn "glibc ${g:-未知} < ${GLIBC_MIN}，gnu 版无法运行，改用静态链接的 musl 版"
    fi
  fi
  [[ "${SS_LIBC}" =~ ^(gnu|musl)$ ]] || die "SS_LIBC 只能是 gnu 或 musl"
}

# 结果：TARGET_VERSION、ASSET_NAME、API_DIGEST（可能为空）
resolve_release() {
  section "获取版本"
  choose_libc
  local api_url json tag pinned=1
  API_DIGEST=""
  if [[ "${SS_VERSION}" == latest ]]; then
    pinned=0; api_url="${SS_API_BASE}/releases/latest"
    info "正在获取 shadowsocks-rust 最新稳定版..."
  else
    TARGET_VERSION="$(normalize_version "${SS_VERSION}")"
    api_url="${SS_API_BASE}/releases/tags/v${TARGET_VERSION}"
    info "使用固定版本 v${TARGET_VERSION}（SS_VERSION=latest 可改用最新版）"
  fi
  if json="$(curl -fsSL --retry 2 --connect-timeout 10 -H 'Accept: application/vnd.github+json' "${api_url}" 2>/dev/null)"; then
    tag="$(jq -r '.tag_name // empty' <<< "${json}")"
    if [[ "$(jq -r '.prerelease' <<< "${json}")" == "true" ]]; then
      [[ "${pinned}" -eq 1 ]] || die "latest 指向预发布版本，已中止"
      warn "v${TARGET_VERSION} 是预发布版本（prerelease）"
    fi
    [[ "${pinned}" -eq 1 ]] || TARGET_VERSION="$(normalize_version "${tag}")"
  else
    [[ "${pinned}" -eq 1 ]] || die "无法访问 GitHub API 获取最新版本，请设置 SS_VERSION 固定版本"
    warn "无法访问 GitHub API，将只用 .sha256 文件校验"
    json=""
  fi
  ASSET_NAME="shadowsocks-v${TARGET_VERSION}.${TRIPLE_ARCH}-unknown-linux-${SS_LIBC}.tar.xz"
  if [[ -n "${json}" ]]; then
    API_DIGEST="$(jq -r --arg n "${ASSET_NAME}" '.assets[]? | select(.name == $n) | .digest // empty' <<< "${json}")"
    API_DIGEST="${API_DIGEST#sha256:}"
    [[ -z "${API_DIGEST}" || "${API_DIGEST}" =~ ^[0-9a-f]{64}$ ]] || die "GitHub API 返回的 digest 格式异常"
  fi
  ok "目标版本：${C_BOLD}v${TARGET_VERSION}${C_RESET}（${SS_LIBC}）"
}

# 下载并校验，解包到 ${TEMP_DIR}/pkg
download_verify() {
  local base="${SS_DOWNLOAD_BASE}/v${TARGET_VERSION}/${ASSET_NAME}"
  local tarball="${TEMP_DIR}/${ASSET_NAME}" sumf="${TEMP_DIR}/${ASSET_NAME}.sha256"
  local actual expected got_ver b
  info "正在下载 ${ASSET_NAME} ..."
  curl -fsSL --retry 2 --connect-timeout 15 --proto '=https,http,file' -o "${tarball}" "$(proxy_url "${base}")" \
    || die "下载失败：${base}"
  curl -fsSL --retry 2 --connect-timeout 15 --proto '=https,http,file' -o "${sumf}" "$(proxy_url "${base}.sha256")" \
    || die "下载校验文件失败：${base}.sha256（拒绝在无校验的情况下安装）"
  actual="$(sha256sum "${tarball}" | awk '{print $1}')"
  expected="$(awk 'NR == 1 { print $1 }' "${sumf}" | tr -d '\r')"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die ".sha256 文件中没有有效的哈希"
  if [[ "${actual}" != "${expected}" ]]; then
    err "SHA256 不匹配！实际：${actual}；.sha256：${expected}"
    die "文件可能被篡改或下载不完整，已中止（未做任何更改）"
  fi
  ok "SHA256 与 .sha256 一致：${actual}"
  if [[ -n "${API_DIGEST}" ]]; then
    [[ "${actual}" == "${API_DIGEST}" ]] || die "SHA256 与 GitHub API digest 不一致（API：${API_DIGEST}），已中止"
    ok "SHA256 与 GitHub API asset digest 一致"
  elif [[ -n "${GITHUB_PROXY}" ]]; then
    warn "使用了第三方代理且未取得 GitHub API digest：.sha256 与文件来自同一代理，请自行评估信任"
  fi
  mkdir -p "${TEMP_DIR}/pkg"
  tar -xJf "${tarball}" -C "${TEMP_DIR}/pkg" ssserver ssservice ssurl || die "解压失败"
  for b in ssserver ssservice ssurl; do chmod 0755 "${TEMP_DIR}/pkg/${b}"; done
  if ! got_ver="$("${TEMP_DIR}/pkg/ssserver" --version 2>/dev/null | awk '{ print $2; exit }')"; then
    die "ssserver 无法在本机运行（${SS_LIBC}）；可尝试 SS_LIBC=musl"
  fi
  [[ "${got_ver}" == "${TARGET_VERSION}" ]] || die "二进制版本 (${got_ver}) 与目标版本 (${TARGET_VERSION}) 不一致"
  ok "二进制自检通过：ssserver ${got_ver}"
}

install_binary() {
  local b
  install -d -m 0755 "${BIN_DIR}"
  for b in ssserver ssservice ssurl; do
    install -m 0755 "${TEMP_DIR}/pkg/${b}" "${BIN_DIR}/${b}.new"
    mv -f "${BIN_DIR}/${b}.new" "${BIN_DIR}/${b}"
  done
  ok "已安装 ssserver / ssservice / ssurl → ${BIN_DIR}"
}

ensure_user() {
  if ! id -u "${SS_USER}" >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin --comment "shadowsocks-rust service" "${SS_USER}"
    ok "已创建系统用户 ${SS_USER}"
  else
    ok "系统用户 ${SS_USER} 已存在"
  fi
}

# ── 读取已有配置 ───────────────────────────────────────────────────────────
jq_cfg() { jq -r "$1" "${SS_CONFIG}" 2>/dev/null || true; }

load_existing() {
  OLD_PORT=""; OLD_METHOD=""; OLD_PSK=""; OLD_NAMES=(); OLD_UPSK=()
  [[ -f "${SS_CONFIG}" ]] || return 0
  OLD_PORT="$(jq_cfg '.servers[0].server_port // empty')"
  OLD_METHOD="$(jq_cfg '.servers[0].method // empty')"
  OLD_PSK="$(jq_cfg '.servers[0].password // empty')"
  local n p
  while IFS=$'\t' read -r n p; do
    [[ -n "${n}" ]] || continue
    OLD_NAMES+=("${n}"); OLD_UPSK+=("${p}")
  done < <(jq_cfg '.servers[0].users[]? | [.name, .password] | @tsv')
}

old_upsk_of() {
  local i
  for i in "${!OLD_NAMES[@]}"; do
    if [[ "${OLD_NAMES[$i]}" == "$1" ]]; then printf '%s\n' "${OLD_UPSK[$i]}"; return 0; fi
  done
  return 1
}

genkey() { "${BIN_DIR}/ssservice" genkey -m "${METHOD}" | tr -d '\r\n'; }

# ── 配置问答 ───────────────────────────────────────────────────────────────
choose_method() {
  section "加密方式（SS2022）"
  local def="${OLD_METHOD:-${DEFAULT_METHOD}}" n
  valid_method "${def}" || def="${DEFAULT_METHOD}"
  if [[ -z "${SS_METHOD}" && "${INTERACTIVE}" -eq 1 ]]; then
    case "${def}" in 2022-blake3-aes-256-gcm) n=2 ;; 2022-blake3-chacha20-poly1305) n=3 ;; *) n=1 ;; esac
    menu_item "1" "2022-blake3-aes-128-gcm" "16 字节密钥，支持多用户；有 AES-NI 时最快（默认）"
    menu_item "2" "2022-blake3-aes-256-gcm" "32 字节密钥，支持多用户"
    menu_item "3" "2022-blake3-chacha20-poly1305" "32 字节密钥，无 AES 硬件加速的设备更快；不支持多用户（EIH）"
    printf '\n' >&2
    while true; do
      ask "请输入选项 [1-3]" "${n}"
      case "${REPLY}" in
        1) SS_METHOD=2022-blake3-aes-128-gcm; break ;;
        2) SS_METHOD=2022-blake3-aes-256-gcm; break ;;
        3) SS_METHOD=2022-blake3-chacha20-poly1305; break ;;
        *) warn "选项无效，请重新输入" ;;
      esac
    done
  fi
  METHOD="${SS_METHOD:-${def}}"
  valid_method "${METHOD}" || die "SS_METHOD 只能是：${METHODS// / | }"
  ok "加密方式：${C_BOLD}${METHOD}${C_RESET}"
  [[ -z "${OLD_METHOD}" || "${OLD_METHOD}" == "${METHOD}" ]] || warn "加密方式 ${OLD_METHOD} → ${METHOD}：所有客户端都必须更新"
}

choose_port() {
  local def cand env_val="${SS_PORT}"
  if [[ "${KEEP}" -eq 1 && -n "${OLD_PORT}" ]]; then def="${OLD_PORT}"; else def="$(random_port)"; fi
  [[ -n "${env_val}" || "${INTERACTIVE}" -eq 1 ]] || env_val="${def}"
  while true; do
    if [[ -n "${env_val}" ]]; then cand="${env_val}"; env_val=""; else ask "监听端口（TCP+UDP）" "${def}"; cand="${REPLY}"; fi
    if ! valid_port "${cand}"; then
      [[ "${INTERACTIVE}" -eq 1 ]] || die "端口无效：${cand}"
      warn "端口无效，请输入 1-65535"; continue
    fi
    cand="$((10#${cand}))"
    if port_in_use "${cand}"; then
      [[ "${INTERACTIVE}" -eq 1 ]] || die "端口 ${cand} 已被其他进程占用"
      warn "端口 ${cand} 已被其他进程占用"; continue
    fi
    PORT="${cand}"; break
  done
  ((PORT >= 1024)) || warn "端口 < 1024：服务以非 root 用户运行，需要 CAP_NET_BIND_SERVICE（已在 systemd 单元中授予）"
  ok "端口 → ${C_BOLD}${PORT}${C_RESET}"
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

choose_users() {
  # 结果：NAMES=()（空 = 单用户）
  NAMES=()
  local spec="${SS_USERS}" cnt def_cnt i n def_n
  if ! supports_eih "${METHOD}"; then
    [[ -z "${spec}" || "${spec}" == single ]] || die "${METHOD} 不支持多用户（EIH），请去掉 SS_USERS 或改用 AES 加密方式"
    ((${#OLD_NAMES[@]} == 0)) || warn "${METHOD} 不支持多用户（EIH），已改为单用户：所有客户端都必须更新"
    info "${METHOD} 不支持多用户（EIH，仅 AES 系列支持），固定为单用户"
    return 0
  fi
  if [[ -z "${spec}" && "${KEEP}" -eq 1 && "${INTERACTIVE}" -ne 1 && ${#OLD_NAMES[@]} -gt 0 ]]; then
    NAMES=("${OLD_NAMES[@]}"); info "沿用已有用户：${NAMES[*]}"; return 0
  fi
  if [[ -z "${spec}" && "${INTERACTIVE}" -eq 1 ]]; then
    def_cnt=1; [[ "${KEEP}" -eq 1 && ${#OLD_NAMES[@]} -gt 0 ]] && def_cnt="${#OLD_NAMES[@]}"
    info "1 = 单用户（一个密码）；≥2 = 多用户（EIH：每个用户独立密钥，可单独删除，客户端密码为 iPSK:uPSK）"
    while true; do
      ask "用户数量" "${def_cnt}"
      [[ "${REPLY}" =~ ^[1-9][0-9]?$ ]] && break
      warn "请输入 1-99"
    done
    cnt="${REPLY}"
    ((cnt >= 2)) || return 0
    for ((i = 1; i <= cnt; i++)); do
      def_n="${OLD_NAMES[$((i - 1))]:-user${i}}"
      while true; do
        ask "第 ${i} 个用户名（字母/数字/_/-）" "${def_n}"
        n="${REPLY}"
        if ! valid_name "${n}"; then warn "用户名只能包含字母、数字、_、-（最长 32）"; continue; fi
        if [[ " ${NAMES[*]} " == *" ${n} "* ]]; then warn "用户名重复"; continue; fi
        break
      done
      NAMES+=("${n}")
    done
  elif [[ -n "${spec}" && "${spec}" != single ]]; then
    IFS=',' read -r -a NAMES <<< "${spec// /}"
    for n in "${NAMES[@]}"; do valid_name "${n}" || die "SS_USERS 中的用户名无效：${n}"; done
    [[ "$(printf '%s\n' "${NAMES[@]}" | sort | uniq -d)" == "" ]] || die "SS_USERS 中有重复用户名"
  fi
  if ((${#NAMES[@]} > 0)); then ok "多用户（EIH）：${NAMES[*]}"; else ok "单用户"; fi
}

make_keys() {
  # 结果：PSK（单用户密码或 EIH 的 iPSK）、UPSK=()（与 NAMES 对应）
  local i n k
  UPSK=()
  if [[ "${KEEP}" -eq 1 ]] && valid_key "${METHOD}" "${OLD_PSK}"; then
    PSK="${OLD_PSK}"; info "沿用已有$([[ ${#NAMES[@]} -gt 0 ]] && echo ' iPSK' || echo '密码')"
  else
    PSK="$(genkey)"
    [[ "${KEEP}" -eq 1 && -n "${OLD_PSK}" ]] && warn "密钥长度与新加密方式不符，已重新生成：所有客户端都必须更新"
  fi
  for i in "${!NAMES[@]}"; do
    n="${NAMES[$i]}"
    if [[ "${KEEP}" -eq 1 ]] && k="$(old_upsk_of "${n}")" && valid_key "${METHOD}" "${k}"; then :; else k="$(genkey)"; fi
    UPSK+=("${k}")
  done
  valid_key "${METHOD}" "${PSK}" || die "密钥生成失败"
  for k in "${UPSK[@]}"; do valid_key "${METHOD}" "${k}" || die "密钥生成失败"; done
  if [[ "${KEEP}" -eq 1 && ${#OLD_NAMES[@]} -eq 0 && ${#NAMES[@]} -gt 0 && -n "${OLD_PSK}" ]]; then
    warn "单用户 → 多用户：原密码改作 iPSK，客户端密码变为 iPSK:uPSK，所有客户端都必须更新"
  fi
  ok "密钥已就绪（ssservice genkey -m ${METHOD}）"
}

# ── 生成文件 ───────────────────────────────────────────────────────────────
build_config() {
  local users='[]' i
  for i in "${!NAMES[@]}"; do
    users="$(jq -c --arg n "${NAMES[$i]}" --arg p "${UPSK[$i]}" '. + [{name: $n, password: $p}]' <<< "${users}")"
  done
  jq -n --argjson port "${PORT}" --arg m "${METHOD}" --arg pw "${PSK}" --argjson users "${users}" --arg acl "${SS_ACL}" '{
    servers: [ ({ server: "::", server_port: $port, method: $m, password: $pw, mode: "tcp_and_udp" }
               + (if ($users | length) > 0 then { users: $users } else {} end)) ],
    timeout: 300,
    udp_timeout: 300,
    udp_max_associations: 4096,
    no_delay: true,
    keep_alive: 15,
    acl: $acl,
    log: { level: 0 },
    runtime: { mode: "multi_thread" }
  }'
}

check_config() {
  # 生成后的自检：方法、密钥长度、禁止字段
  local f="$1" bad
  bad="$(jq -r --argjson fk "${FORBIDDEN_KEYS}" '[paths | .[-1] | strings | select(. as $k | $fk | index($k))] | unique | join(",")' "${f}")"
  [[ -z "${bad}" ]] || die "配置包含禁止字段：${bad}"
  [[ "$(jq -r '[.servers[].method] | unique | join(",")' "${f}")" == "${METHOD}" ]] || die "配置中的 method 异常"
}

write_acl() {
  cat > "$1" <<'EOF'
# 由 ssrust-install-script 生成：允许访问公网，禁止访问内网 / 本机 / 保留地址
# 注：不写 ::ffff:0:0/96，ssserver 的双栈 UDP 出站会把 IPv4 目标映射成 ::ffff:a.b.c.d，写上会误杀所有 IPv4 UDP；
#     映射地址实际发出的是 IPv4 包，由 nftables 防护层的 IPv4 规则兜底。
[accept_all]

[outbound_block_list]
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.0.0.0/24
192.168.0.0/16
198.18.0.0/15
224.0.0.0/4
240.0.0.0/4
::/128
::1/128
64:ff9b::/96
fc00::/7
fe80::/10
ff00::/8
|localhost
EOF
}

install_root_file() {
  # install_root_file 源 目标 模式 → root:shadowsocks，变化时备份
  local src="$1" dst="$2" mode="$3" bak
  if [[ -f "${dst}" ]] && ! cmp -s "${src}" "${dst}"; then
    bak="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "${dst}" "${bak}"; chmod 0600 "${bak}"
    info "已备份 → ${bak}"
  fi
  install -m "${mode}" -o root -g "${SS_USER}" "${src}" "${dst}.new"
  mv -f "${dst}.new" "${dst}"
}

write_unit() {
  install -d -m 0755 /etc/systemd/system
  cat > "${SS_UNIT}.tmp" <<'EOF'
# 由 ssrust-install-script 生成
[Unit]
Description=shadowsocks-rust server (SS2022)
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target nss-lookup.target ss-rust-guard.service
Wants=network-online.target

[Service]
Type=simple
User=shadowsocks
Group=shadowsocks
ExecStart=/usr/local/bin/ssserver --log-without-time -c /etc/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535
TasksMax=4096

# 只保留绑定低端口所需能力（使用 ≥1024 端口时实际不需要）
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# 文件系统隔离：整个系统只读；日志走 journal
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadOnlyPaths=/etc/shadowsocks-rust
UMask=0077

# 其他加固
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RemoveIPC=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${SS_UNIT}.tmp"
  mv -f "${SS_UNIT}.tmp" "${SS_UNIT}"
  ok "systemd 服务已写入 ${SS_UNIT}"
}

resolver_accepts() {
  # 放行 /etc/resolv.conf 中位于内网/本机的 DNS 服务器（否则 ssserver 无法解析域名）
  local ns v4="" v6=""
  while read -r ns; do
    ns="${ns%%%*}"
    if is_ipv4 "${ns}"; then v4+="${v4:+, }${ns}"; elif is_ipv6 "${ns}"; then v6+="${v6:+, }${ns}"; fi
  done < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null)
  [[ -z "${v4}" ]] || printf '\t\tmeta skuid "%s" ip daddr { %s } meta l4proto { tcp, udp } th dport 53 accept\n' "${SS_USER}" "${v4}"
  [[ -z "${v6}" ]] || printf '\t\tmeta skuid "%s" ip6 daddr { %s } meta l4proto { tcp, udp } th dport 53 accept\n' "${SS_USER}" "${v6}"
}

write_nft() {
  if ! is_true "${NFT_GUARD}"; then
    if [[ -f "${NFT_UNIT}" ]]; then
      systemctl disable --now ss-rust-guard.service >/dev/null 2>&1 || true
      rm -f "${NFT_UNIT}" "${NFT_FILE}"
      info "已移除 nftables 防护（NFT_GUARD=0）"
    fi
    warn "nftables 按 uid 拦截已关闭：只依赖 ACL 阻止访问内网"
    return 0
  fi
  local tmp="${TEMP_DIR}/guard.nft"
  {
    cat <<EOF
#!/usr/sbin/nft -f
# 由 ssrust-install-script 生成：禁止 ${SS_USER} 用户（ssserver）向内网 / 本机 / 保留地址发起连接
# ACL 之外的纵深防御（防 DNS rebinding 等）。独立的表，不影响已有规则；重新加载前先删除自身。
table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}

table inet ${NFT_TABLE} {
	chain output {
		type filter hook output priority filter; policy accept;
		# 只拦截 ssserver 主动发起的新连接；已建立连接的回包（含来自内网客户端的连接）放行
		ct state established,related accept
EOF
    resolver_accepts
    cat <<EOF
		meta skuid "${SS_USER}" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3 } counter reject
		meta skuid "${SS_USER}" ip6 daddr { ::/127, ::ffff:0:0/96, 64:ff9b::/96, fc00::/7, fe80::/10, ff00::/8 } counter reject
	}
}
EOF
  } > "${tmp}"
  install -m 0644 "${tmp}" "${NFT_FILE}"
  cat > "${NFT_UNIT}" <<'EOF'
# 由 ssrust-install-script 生成
[Unit]
Description=nftables guard: block private/loopback destinations for shadowsocks user
After=nftables.service
Before=ss-rust.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/shadowsocks-rust/guard.nft
ExecStop=-/usr/sbin/nft delete table inet ss_rust_guard

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${NFT_UNIT}"
  if ! nft -c -f "${NFT_FILE}" >/dev/null 2>&1; then
    warn "nftables 规则校验失败（容器内通常缺少 CAP_NET_ADMIN）；ACL 仍然生效"
  fi
  ok "nftables 防护规则已写入 ${NFT_FILE}"
}

enable_ntp() {
  # SS2022 要求客户端与服务端时间差 ≤ 30 秒
  [[ "${USE_SYSTEMD}" -eq 1 ]] || return 0
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
    ok "系统时间已通过 NTP 同步"; return 0
  fi
  if systemd-detect-virt -cq 2>/dev/null; then
    info "容器环境：时间由宿主机提供，跳过 NTP 设置（请确保宿主机已对时）"; return 0
  fi
  if ! dpkg-query -W -f='${Status}' systemd-timesyncd 2>/dev/null | grep -q "install ok installed" \
     && ! dpkg-query -W -f='${Status}' chrony 2>/dev/null | grep -q "install ok installed" \
     && ! dpkg-query -W -f='${Status}' ntpsec 2>/dev/null | grep -q "install ok installed"; then
    info "正在安装 systemd-timesyncd ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd-timesyncd >/dev/null 2>&1 \
      || warn "systemd-timesyncd 安装失败，请自行配置 NTP"
  fi
  if timedatectl set-ntp true >/dev/null 2>&1; then ok "已启用 NTP 自动对时（SS2022 时间差超过 30 秒会拒绝连接）"
  else warn "无法启用 NTP（timedatectl set-ntp true 失败），请自行确保时间准确：SS2022 时间差超过 30 秒会拒绝连接"; fi
}

restart_service() {
  if [[ "${USE_SYSTEMD}" -eq 0 ]] || is_true "${SKIP_START}"; then
    warn "已跳过启动服务（SKIP_START / 无 systemd）"; return 0
  fi
  info "正在启动 ss-rust 服务..."
  systemctl daemon-reload
  if [[ -f "${NFT_UNIT}" ]]; then
    systemctl enable ss-rust-guard.service >/dev/null 2>&1 || true
    if ! systemctl restart ss-rust-guard.service; then
      warn "nftables 防护加载失败，ss-rust 仍会启动（ACL 仍然生效）；排查：journalctl -u ss-rust-guard（容器内通常缺少 CAP_NET_ADMIN）"
    fi
  fi
  systemctl enable ss-rust.service >/dev/null 2>&1
  systemctl reset-failed ss-rust.service >/dev/null 2>&1 || true
  if systemctl restart ss-rust.service; then
    sleep 2
    systemctl is-active --quiet ss-rust.service && { ok "ss-rust 服务运行中"; return 0; }
  fi
  journalctl -u ss-rust.service -n 20 --no-pager -o cat >&2 || true
  return 1
}

# ── 客户端信息 ─────────────────────────────────────────────────────────────
detect_address() {
  if [[ -z "${SERVER_ADDRESS}" && -f "${CLIENT_YAML}" ]]; then
    SERVER_ADDRESS="$(awk '/^  server: / { print $2; exit }' "${CLIENT_YAML}" | tr -d '"')"
    [[ "${SERVER_ADDRESS}" != "YOUR_SERVER_IP" ]] || SERVER_ADDRESS=""
  fi
  if [[ -z "${SERVER_ADDRESS}" && "${DETECT_PUBLIC_IP}" == 1 ]]; then
    SERVER_ADDRESS="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    is_ipv4 "${SERVER_ADDRESS}" || SERVER_ADDRESS="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  fi
  [[ -n "${SERVER_ADDRESS}" ]] || SERVER_ADDRESS="$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
  SERVER_ADDRESS="${SERVER_ADDRESS:-YOUR_SERVER_IP}"
  [[ "${SERVER_ADDRESS}" =~ ^[A-Za-z0-9.:_-]+$ ]] || die "SERVER_ADDRESS 只能是 IP 或域名"
}

yaml_val() {
  local v="$1"
  if [[ "${v}" =~ ^[-+]?([0-9_]+(\.[0-9_]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$ || "${v}" =~ ^0[xXoObB] || "${v,,}" =~ ^(true|false|yes|no|on|off|y|n|null|~)$ ]]; then
    printf '"%s"' "${v}"
  else
    printf '%s' "${v}"
  fi
}

write_client_files() {
  local yaml="proxies:" links="" srv i name pw j
  srv="$(yaml_val "${SERVER_ADDRESS}")"
  local -a nn=() pp=()
  if ((${#NAMES[@]} == 0)); then nn=("${NODE_NAME}"); pp=("${PSK}")
  else for i in "${!NAMES[@]}"; do nn+=("${NODE_NAME}-${NAMES[$i]}"); pp+=("${PSK}:${UPSK[$i]}"); done; fi
  for i in "${!nn[@]}"; do
    name="${nn[$i]}"; pw="${pp[$i]}"
    yaml+="
- name: ${name}
  type: ss
  server: ${srv}
  port: ${PORT}
  cipher: ${METHOD}
  password: \"${pw}\"
  udp: true"
    j="$(jq -n --arg s "${SERVER_ADDRESS}" --argjson p "${PORT}" --arg m "${METHOD}" --arg pw "${pw}" --arg r "${name}" \
      '{servers: [{server: $s, server_port: $p, method: $m, password: $pw, remarks: $r}]}')"
    printf '%s\n' "${j}" > "${TEMP_DIR}/url.json"
    links+="$("${BIN_DIR}/ssurl" -e "${TEMP_DIR}/url.json")
"
    rm -f "${TEMP_DIR}/url.json"
  done
  ( umask 077; printf '%s\n' "${yaml}" > "${CLIENT_YAML}"; printf '%s' "${links}" > "${LINKS_FILE}" )
  chmod 0600 "${CLIENT_YAML}" "${LINKS_FILE}"; chown root:root "${CLIENT_YAML}" "${LINKS_FILE}"
}

print_client_info() {
  section "客户端配置（mihomo proxies）"
  printf '\n' >&2
  cat "${CLIENT_YAML}"
  section "分享链接（ss://，SIP002）"
  printf '\n' >&2
  cat "${LINKS_FILE}"
  printf '\n' >&2
  info "服务器地址：${C_BOLD}${SERVER_ADDRESS}${C_RESET}；加密方式：${METHOD}"
  info "请在防火墙/安全组放行 ${C_BOLD}TCP + UDP${C_RESET} 端口 ${C_BOLD}${PORT}${C_RESET}（本脚本不修改你的防火墙规则）"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    info "  检测到 ufw：ufw allow ${PORT}/tcp && ufw allow ${PORT}/udp"
  fi
  info "客户端 YAML：${CLIENT_YAML}（权限 600）；链接：${LINKS_FILE}"
  info "SS2022 要求两端时间差 ≤ 30 秒，客户端设备也要开启自动对时"
  ((${#NAMES[@]} == 0)) || info "多用户（EIH）：客户端密码为 iPSK:uPSK；需要较新的客户端（mihomo / sing-box / ss-rust）"
}

success_box() {
  printf '\n%s%s  ════════════════════════════════════════════════════\n' "${C_GREEN}" "${C_BOLD}" >&2
  printf '    ✔  %s\n' "$1" >&2
  printf '  ════════════════════════════════════════════════════%s\n' "${C_RESET}" >&2
}

# ── 动作 ───────────────────────────────────────────────────────────────────
do_install() {
  ensure_deps
  prompt_github_proxy
  load_existing
  KEEP=0
  if [[ -f "${SS_CONFIG}" ]]; then
    if [[ -n "${KEEP_KEYS}" ]]; then is_true "${KEEP_KEYS}" && KEEP=1
    elif yes_no "检测到已有配置，沿用现有端口、用户与密钥（未改动的客户端无需更新）？" 1; then KEEP=1; fi
    if [[ "${KEEP}" -eq 1 ]]; then ok "将沿用已有设置"; else warn "将生成全新密钥，旧客户端配置将失效"; fi
  fi

  # 先收集并校验所有输入，再下载
  choose_method
  section "端口与用户"
  choose_port
  choose_users

  resolve_release
  TEMP_DIR="$(mktemp -d)"
  local cur=""; cur="$(installed_version || true)"
  section "下载安装"
  if [[ "${cur}" == "${TARGET_VERSION}" && -x "${BIN_DIR}/ssservice" && -x "${BIN_DIR}/ssurl" ]] && ! is_true "${FORCE_DOWNLOAD}"; then
    ok "已安装 shadowsocks-rust v${cur}，跳过下载（FORCE_DOWNLOAD=1 可强制重新下载并校验）"
  else
    download_verify
    install_binary
  fi
  ensure_user

  section "生成密钥与配置"
  make_keys
  ( umask 077; build_config > "${TEMP_DIR}/config.json"; write_acl "${TEMP_DIR}/server.acl" )
  check_config "${TEMP_DIR}/config.json"
  install -d -m 0750 -o root -g "${SS_USER}" "${SS_ETC}"
  chown root:"${SS_USER}" "${SS_ETC}"; chmod 0750 "${SS_ETC}"
  local prev_cfg=""
  if [[ -f "${SS_CONFIG}" ]]; then prev_cfg="${TEMP_DIR}/prev.json"; cp -p "${SS_CONFIG}" "${prev_cfg}"; fi
  install_root_file "${TEMP_DIR}/server.acl" "${SS_ACL}" 0640
  install_root_file "${TEMP_DIR}/config.json" "${SS_CONFIG}" 0640
  ok "配置已写入 ${SS_CONFIG}、${SS_ACL}（640 root:${SS_USER}）"
  write_unit
  write_nft
  enable_ntp

  section "启动服务"
  if ! restart_service; then
    if [[ -n "${prev_cfg}" ]]; then
      install -m 0640 -o root -g "${SS_USER}" "${prev_cfg}" "${SS_CONFIG}"
      systemctl restart ss-rust.service >/dev/null 2>&1 || true
      die "ss-rust 服务启动失败，已恢复旧配置；请检查上方日志"
    fi
    die "ss-rust 服务启动失败，请检查上方日志"
  fi

  detect_address
  write_client_files
  success_box "安装完成：shadowsocks-rust v${TARGET_VERSION}（${METHOD}）"
  print_client_info
}

do_update() {
  [[ -x "${SS_BIN}" ]] || die "未检测到已安装的 shadowsocks-rust，请先安装"
  ensure_deps
  prompt_github_proxy
  resolve_release
  local cur b; cur="$(installed_version || true)"
  section "更新 shadowsocks-rust"
  if [[ "${cur}" == "${TARGET_VERSION}" ]] && ! is_true "${FORCE_DOWNLOAD}"; then
    ok "当前已是 v${cur}，无需更新（SS_VERSION=latest 可检查最新版）"; return 0
  fi
  info "升级路径：v${cur:-未知} → ${C_BOLD}v${TARGET_VERSION}${C_RESET}"
  TEMP_DIR="$(mktemp -d)"
  download_verify
  mkdir -p "${TEMP_DIR}/old"
  for b in ssserver ssservice ssurl; do [[ ! -f "${BIN_DIR}/${b}" ]] || cp -p "${BIN_DIR}/${b}" "${TEMP_DIR}/old/"; done
  install_binary
  if ! restart_service; then
    warn "新版本启动失败，正在回滚到 v${cur} ..."
    for b in ssserver ssservice ssurl; do [[ ! -f "${TEMP_DIR}/old/${b}" ]] || install -m 0755 "${TEMP_DIR}/old/${b}" "${BIN_DIR}/${b}"; done
    systemctl restart ss-rust.service >/dev/null 2>&1 || true
    die "更新失败，已回滚"
  fi
  success_box "更新完成：shadowsocks-rust v${TARGET_VERSION}"
  info "现有配置已保留：${SS_CONFIG}"
}

do_info() {
  [[ -f "${SS_CONFIG}" ]] || die "未找到 ${SS_CONFIG}"
  load_existing
  METHOD="${OLD_METHOD}"; PORT="${OLD_PORT}"; PSK="${OLD_PSK}"
  NAMES=("${OLD_NAMES[@]}"); UPSK=("${OLD_UPSK[@]}")
  [[ -n "${METHOD}" && -n "${PORT}" && -n "${PSK}" ]] || die "无法解析 ${SS_CONFIG}"
  TEMP_DIR="$(mktemp -d)"
  detect_address
  write_client_files
  print_client_info
}

do_uninstall() {
  section "卸载 shadowsocks-rust"
  if [[ "${INTERACTIVE}" -eq 1 ]]; then
    yes_no "确认卸载 shadowsocks-rust？" 0 || { info "已取消"; return 0; }
    [[ "${PURGE}" == 1 ]] || { yes_no "同时删除配置目录 ${SS_ETC} 与 ${SS_USER} 用户？" 0 && PURGE=1; } || true
  fi
  if [[ "${USE_SYSTEMD}" -eq 1 ]]; then
    systemctl disable --now ss-rust.service >/dev/null 2>&1 || true
    systemctl disable --now ss-rust-guard.service >/dev/null 2>&1 || true
  fi
  rm -f "${SS_UNIT}" "${NFT_UNIT}" "${BIN_DIR}/ssserver" "${BIN_DIR}/ssservice" "${BIN_DIR}/ssurl"
  if [[ "${USE_SYSTEMD}" -eq 1 ]]; then
    systemctl daemon-reload || true
    systemctl reset-failed ss-rust.service ss-rust-guard.service >/dev/null 2>&1 || true
  fi
  if command -v nft >/dev/null 2>&1 && nft list table inet "${NFT_TABLE}" >/dev/null 2>&1; then
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
  fi
  ok "已删除二进制、systemd 服务与 nftables 表"
  if [[ "${PURGE}" == 1 ]]; then
    rm -rf "${SS_ETC}"
    if id -u "${SS_USER}" >/dev/null 2>&1; then userdel "${SS_USER}" 2>/dev/null || true; fi
    ok "已删除配置目录与 ${SS_USER} 用户"
  else
    info "配置已保留：${SS_ETC}（PURGE=1 或 --purge 可一并删除）"
  fi
}

main_menu() {
  section "检测到已安装 shadowsocks-rust v$(installed_version || echo 未知)"
  menu_item "1" "更新 shadowsocks-rust" "保留配置，校验 SHA256"
  menu_item "2" "重新配置" "可沿用现有端口/用户/密钥"
  menu_item "3" "查看客户端配置"
  menu_item "4" "卸载"
  menu_item "0" "退出"
  printf '\n' >&2
  while true; do
    ask "请输入选项 [0-4]" ""
    case "${REPLY}" in
      1) SS_ACTION=update; return ;;
      2) SS_ACTION=reconfigure; return ;;
      3) SS_ACTION=info; return ;;
      4) SS_ACTION=uninstall; return ;;
      0) info "已退出"; exit 0 ;;
      *) warn "选项无效，请重新输入" ;;
    esac
  done
}

main() {
  while (($# > 0)); do
    case "$1" in
      install|update|reconfigure|info|uninstall) SS_ACTION="$1" ;;
      --purge) PURGE=1 ;;
      -y|--yes) NONINTERACTIVE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "未知参数：$1" ;;
    esac
    shift
  done
  if is_true "${NONINTERACTIVE}" || [[ ! -t 0 ]]; then INTERACTIVE=0; fi
  is_true "${PURGE}" && PURGE=1 || PURGE=0

  banner
  info "脚本版本 ${SCRIPT_VERSION}$([[ ${INTERACTIVE} -eq 0 ]] && echo '（非交互模式）')"
  preflight

  if [[ -z "${SS_ACTION}" ]]; then
    if [[ -x "${SS_BIN}" && "${INTERACTIVE}" -eq 1 ]]; then main_menu; else SS_ACTION=install; fi
  fi
  case "${SS_ACTION}" in
    install|reconfigure) do_install ;;
    update) do_update ;;
    info) do_info ;;
    uninstall) do_uninstall ;;
    *) die "未知操作：${SS_ACTION}" ;;
  esac
  printf '\n' >&2
}

main "$@"
