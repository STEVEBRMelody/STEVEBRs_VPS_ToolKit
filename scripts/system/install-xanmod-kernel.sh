#!/usr/bin/env bash
set -Eeuo pipefail

KEY_URL="https://dl.xanmod.org/archive.key"
KEYRING_PATH="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
SOURCE_LIST_PATH="/etc/apt/sources.list.d/xanmod-release.list"
REPO_URL="http://deb.xanmod.org"
KERNEL_PACKAGE="linux-xanmod-x64v3"

ASSUME_YES=0
TMP_KEY=""
TMP_KEYRING=""

info() {
  printf '[INFO] %s\n' "$*"
}

success() {
  printf '[OK] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

error() {
  printf '[ERR] %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="${1:-是否继续？}"
  local answer=""

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 0
  fi

  printf '[WARN] %s [y/N]: ' "$prompt" >&2
  if ! read -r answer; then
    return 1
  fi

  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "请使用 root 权限运行此脚本。"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  printf '[ERR] 脚本在第 %s 行失败，退出码：%s\n' "$line_no" "$exit_code" >&2
  exit "$exit_code"
}

cleanup() {
  if [[ -n "${TMP_KEY:-}" && -f "${TMP_KEY}" ]]; then
    rm -f -- "${TMP_KEY}"
  fi

  if [[ -n "${TMP_KEYRING:-}" && -f "${TMP_KEYRING}" ]]; then
    rm -f -- "${TMP_KEYRING}"
  fi
}

trap 'on_error "$LINENO"' ERR
trap cleanup EXIT

usage() {
  cat <<'EOF'
用法:
  install-xanmod-kernel.sh [选项]

选项:
  -y, --yes        跳过确认提示
  -h, --help       显示帮助

说明:
  此脚本仅支持 Debian，并安装 linux-xanmod-x64v3。
  安装第三方内核可能影响启动，请确保 VPS 控制台可用。
EOF
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        ASSUME_YES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "未知参数：$1"
        ;;
    esac
    shift
  done
}

detect_pkg_manager() {
  if command_exists apt-get; then
    printf 'apt-get\n'
  elif command_exists dnf; then
    printf 'dnf\n'
  elif command_exists yum; then
    printf 'yum\n'
  elif command_exists apk; then
    printf 'apk\n'
  else
    printf 'unknown\n'
  fi
}

is_debian() {
  [[ -r /etc/os-release ]] || return 1

  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "debian" ]]
}

get_debian_codename() {
  local codename=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi

  if [[ -z "$codename" ]] && command_exists lsb_release; then
    codename="$(lsb_release -sc 2>/dev/null || true)"
  fi

  if [[ -z "$codename" && -r /etc/debian_version ]]; then
    case "$(cut -d. -f1 /etc/debian_version)" in
      11) codename="bullseye" ;;
      12) codename="bookworm" ;;
      13) codename="trixie" ;;
      14) codename="forky" ;;
    esac
  fi

  [[ -n "$codename" ]] || error "无法识别 Debian 版本代号。"
  printf '%s\n' "$codename"
}

check_arch() {
  local arch=""

  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ "$arch" != "amd64" ]]; then
    error "当前架构为 ${arch:-unknown}，linux-xanmod-x64v3 仅适合 amd64。"
  fi

  success "系统架构检查通过：amd64。"
}

ensure_apt_dependencies() {
  local packages=("ca-certificates" "gnupg" "wget")
  local missing=()
  local pkg=""

  for pkg in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$pkg")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    success "依赖已安装：${packages[*]}。"
    return 0
  fi

  info "准备安装缺失依赖：${missing[*]}。"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  success "依赖安装完成。"
}

backup_file() {
  local target="$1"
  local backup=""

  if [[ ! -e "$target" ]]; then
    return 0
  fi

  backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a -- "$target" "$backup"
  success "已备份：$target -> $backup"
}

download_https_file() {
  local url="$1"
  local output="$2"

  case "$url" in
    https://*) ;;
    *) error "拒绝下载非 HTTPS 地址：$url" ;;
  esac

  if command_exists curl; then
    info "使用 curl 下载：$url"
    curl -fsSL --retry 3 --connect-timeout 15 -o "$output" "$url"
  elif command_exists wget; then
    info "使用 wget 下载：$url"
    wget -q --tries=3 --timeout=20 -O "$output" "$url"
  else
    error "未找到 curl 或 wget，无法下载外部资源。"
  fi

  if [[ ! -s "$output" ]]; then
    error "下载失败或文件为空：$url"
  fi
}

install_xanmod_keyring() {
  install -d -m 0755 /etc/apt/keyrings

  TMP_KEY="$(mktemp)"
  TMP_KEYRING="$(mktemp)"

  download_https_file "$KEY_URL" "$TMP_KEY"

  info "转换 XanMod PGP key 为 APT keyring。"
  gpg --dearmor --yes --output "$TMP_KEYRING" "$TMP_KEY"

  if [[ ! -s "$TMP_KEYRING" ]]; then
    error "生成 keyring 失败：$TMP_KEYRING"
  fi

  if [[ -f "$KEYRING_PATH" ]] && cmp -s "$TMP_KEYRING" "$KEYRING_PATH"; then
    success "XanMod keyring 已是最新，无需更新。"
    return 0
  fi

  backup_file "$KEYRING_PATH"
  install -m 0644 "$TMP_KEYRING" "$KEYRING_PATH"
  success "XanMod keyring 已写入：$KEYRING_PATH"
}

write_xanmod_source() {
  local codename="$1"
  local repo_line="deb [signed-by=${KEYRING_PATH}] ${REPO_URL} ${codename} main"
  local current=""

  if [[ -f "$SOURCE_LIST_PATH" ]]; then
    current="$(cat "$SOURCE_LIST_PATH")"
  fi

  if [[ "$current" == "$repo_line" ]]; then
    success "XanMod APT 源已存在且内容一致，无需更新。"
    return 0
  fi

  backup_file "$SOURCE_LIST_PATH"
  printf '%s\n' "$repo_line" > "$SOURCE_LIST_PATH"
  success "XanMod APT 源已写入：$SOURCE_LIST_PATH"
}

install_xanmod_kernel() {
  info "更新 APT 缓存。"
  apt-get update

  if ! apt-cache show "$KERNEL_PACKAGE" >/dev/null 2>&1; then
    error "未在当前 XanMod 仓库中找到软件包：$KERNEL_PACKAGE。请检查 Debian 代号是否受支持。"
  fi

  info "准备安装：$KERNEL_PACKAGE"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends "$KERNEL_PACKAGE"
  success "XanMod 内核安装完成：$KERNEL_PACKAGE"
}

main() {
  local pkg_manager=""
  local codename=""

  parse_args "$@"
  need_root

  pkg_manager="$(detect_pkg_manager)"
  if [[ "$pkg_manager" != "apt-get" ]]; then
    error "此脚本仅支持 Debian APT 环境。当前检测到包管理器：$pkg_manager"
  fi

  if ! is_debian; then
    error "此脚本仅支持 Debian，不支持 Ubuntu、CentOS、Rocky、AlmaLinux、Fedora 或 Alpine。"
  fi

  codename="$(get_debian_codename)"
  info "检测到 Debian 代号：$codename"

  case "$codename" in
    bookworm|trixie|forky|sid)
      success "Debian 代号看起来在 XanMod 常见支持范围内。"
      ;;
    *)
      warn "当前 Debian 代号可能不在 XanMod 官方常见支持范围内：$codename"
      confirm "仍然继续添加 XanMod 源并尝试安装吗？" || error "用户取消操作。"
      ;;
  esac

  check_arch

  warn "此操作将安装第三方 XanMod 内核，并可能影响系统启动。"
  warn "建议确认 VPS 控制台、快照或救援模式可用后再继续。"
  confirm "确认继续安装 linux-xanmod-x64v3 吗？" || error "用户取消操作。"

  ensure_apt_dependencies
  install_xanmod_keyring
  write_xanmod_source "$codename"
  install_xanmod_kernel

  success "全部完成。请重启 VPS 后执行：uname -r"
  warn "脚本不会自动重启系统，请手动确认后再 reboot。"
}

main "$@"
