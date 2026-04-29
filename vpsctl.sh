#!/usr/bin/env bash
# VPS All-in-One Toolkit - GitHub Lite
#
# Recommended GitHub repo structure:
#   your-repo/
#   ├── vpsctl.sh
#   ├── registry/
#   │   └── scripts.conf
#   └── scripts/
#       ├── network/bbr.sh
#       └── app/install-nginx.sh
#
# First-time usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/vpsctl.sh)
#
# Edit GITHUB_OWNER and GITHUB_REPO before pushing to GitHub.

set -Eeuo pipefail

APP_NAME="vpsctl"
APP_VERSION="1.3.0-github-lite"
CONFIG_DIR="/etc/vpsctl"
LOG_FILE="/var/log/vpsctl.log"
TMP_DIR="/tmp/vpsctl.$$"

# ==================== GitHub remote script registry ====================
GITHUB_OWNER="${VPSCTL_GITHUB_OWNER:-STEVEBRMelody}"
GITHUB_REPO="${VPSCTL_GITHUB_REPO:-STEVEBRs_VPS_ToolKit}"
GITHUB_BRANCH="${VPSCTL_GITHUB_BRANCH:-main}"

GITHUB_RAW_BASE="${VPSCTL_GITHUB_RAW_BASE:-https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_BRANCH}}"
REMOTE_REGISTRY_URL="${VPSCTL_REMOTE_REGISTRY_URL:-${GITHUB_RAW_BASE}/registry/scripts.conf}"
# =======================================================================

RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
BLUE='[0;34m'
NC='[0m'

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  local level="$1"; shift
  local msg="$*"
  printf '[%s] [%s] %s
' "$(date '+%F %T')" "$level" "$msg" | tee -a "$LOG_FILE" >/dev/null || true
}

info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; log INFO "$*"; }
success() { echo -e "${GREEN}[OK]${NC} $*" >&2; log OK "$*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; log WARN "$*"; }
error() { echo -e "${RED}[ERR]${NC} $*" >&2; log ERROR "$*"; }

pause() {
  echo
  read -r -p "按回车继续..." _ || true
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "请使用 root 运行：sudo bash $0"
    exit 1
  fi
}

confirm() {
  local prompt="${1:-确认继续？}"
  local ans
  read -r -p "$prompt [y/N]: " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

init_layout() {
  mkdir -p "$CONFIG_DIR"
  touch "$LOG_FILE"
}

show_header() {
  clear || true
  echo "============================================================"
  echo " $APP_NAME $APP_VERSION"
  echo "============================================================"
  echo " Hostname : $(hostname 2>/dev/null || echo unknown)"
  echo " Kernel   : $(uname -sr 2>/dev/null || echo unknown)"
  echo " User     : $(id -un 2>/dev/null || echo unknown)"
  echo " GitHub   : ${GITHUB_OWNER}/${GITHUB_REPO}@${GITHUB_BRANCH}"
  echo " Log      : $LOG_FILE"
  echo " Config   : $CONFIG_DIR"
  echo "============================================================"
  echo
}

download_file() {
  local url="$1"
  local out="$2"

  if command_exists curl; then
    curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$out"
  elif command_exists wget; then
    wget -q --timeout=120 -O "$out" "$url"
  else
    error "系统没有 curl 或 wget，无法下载。"
    return 1
  fi
}

resolve_repo_path() {
  local value="$1"
  value="${value#/}"

  if [[ "$value" =~ ^https?:// ]]; then
    error "当前版本只允许 GitHub 仓库内相对路径，不允许外部 URL：$value"
    return 1
  fi

  echo "${GITHUB_RAW_BASE}/${value}"
}

os_info() {
  show_header
  echo "系统信息："
  echo "------------------------------------------------------------"
  if [[ -f /etc/os-release ]]; then
    sed -n 's/^PRETTY_NAME=/OS=/p' /etc/os-release | tr -d '"'
  fi
  echo "CPU: $(nproc 2>/dev/null || echo unknown) cores"
  echo "RAM: $(free -h 2>/dev/null | awk '/Mem:/ {print $2 " total, " $3 " used"}' || echo unknown)"
  echo "Disk:"
  df -hT / 2>/dev/null || true
  echo
  echo "IP 地址："
  ip -br addr 2>/dev/null || hostname -I 2>/dev/null || true
  pause
}

update_system() {
  show_header
  info "准备更新系统软件包。"
  if ! confirm "确认执行系统更新？"; then
    warn "已取消。"
    pause
    return
  fi

  if command_exists apt-get; then
    apt-get update -y && apt-get upgrade -y
  elif command_exists dnf; then
    dnf upgrade -y
  elif command_exists yum; then
    yum update -y
  elif command_exists apk; then
    apk update && apk upgrade
  else
    error "未识别包管理器。"
    pause
    return
  fi

  success "系统更新完成。"
  pause
}

check_github_config() {
  if [[ "$GITHUB_OWNER" == "YOUR_NAME" || "$GITHUB_REPO" == "YOUR_REPO" ]]; then
    error "GitHub 仓库尚未配置。请先编辑脚本顶部的 GITHUB_OWNER/GITHUB_REPO。"
    return 1
  fi
}

fetch_remote_registry() {
  local out="$1"

  check_github_config || return 1

  info "正在从 GitHub 获取脚本索引：$REMOTE_REGISTRY_URL"
  download_file "$REMOTE_REGISTRY_URL" "$out"
}

list_registry_entries() {
  local file_path="$1"

  [[ -s "$file_path" ]] || return 0

  awk '
    BEGIN { FS="|" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF >= 4 { print $0 }
  ' "$file_path"
}

load_github_script_entries() {
  local registry_tmp="$TMP_DIR/scripts.remote.conf"

  if ! fetch_remote_registry "$registry_tmp"; then
    error "获取 GitHub 脚本索引失败。请检查仓库是否公开、分支是否正确、registry/scripts.conf 是否存在。"
    return 1
  fi

  list_registry_entries "$registry_tmp"
}

verify_sha256() {
  local file="$1"
  local expected="${2:-}"

  [[ -z "$expected" ]] && return 0

  local actual
  if command_exists sha256sum; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif command_exists shasum; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    error "系统没有 sha256sum/shasum，无法校验。"
    return 1
  fi

  if [[ "${actual,,}" != "${expected,,}" ]]; then
    error "SHA256 不匹配。"
    echo "Expected: $expected"
    echo "Actual  : $actual"
    return 1
  fi

  success "SHA256 校验通过。"
}

preview_file() {
  local file="$1"
  echo "------------------------------------------------------------"
  echo "脚本前 80 行预览："
  echo "------------------------------------------------------------"
  sed -n '1,80p' "$file" || true
  echo "------------------------------------------------------------"
}

run_one_script_entry() {
  local name desc path runner sha url file

  name="$1"
  desc="$2"
  path="$3"
  runner="$4"
  sha="${5:-}"

  if ! url="$(resolve_repo_path "$path")"; then
    pause
    return
  fi

  echo
  echo "来源：GitHub"
  echo "名称：$name"
  echo "描述：$desc"
  echo "路径：$path"
  echo "URL ：$url"
  echo "运行器：$runner"
  echo "SHA256：${sha:-未设置}"
  echo
  warn "风险提示：脚本会以 root 权限运行，请确认你的 GitHub 仓库内容可信。"

  if ! confirm "是否下载并预览？"; then
    warn "已取消。"
    pause
    return
  fi

  file="$TMP_DIR/${name}.script"
  info "正在下载脚本..."
  if ! download_file "$url" "$file"; then
    error "下载失败。"
    pause
    return
  fi

  chmod 600 "$file"

  if ! verify_sha256 "$file" "$sha"; then
    pause
    return
  fi

  preview_file "$file"

  if ! confirm "确认执行这个脚本？"; then
    warn "已取消执行。"
    pause
    return
  fi

  info "开始执行：$name"
  chmod +x "$file"

  case "$runner" in
    bash) bash "$file" ;;
    sh) sh "$file" ;;
    python3) python3 "$file" ;;
    *) error "未知运行器：$runner"; pause; return ;;
  esac

  success "脚本执行结束：$name"
  pause
}

run_registry_script() {
  show_header

  mapfile -t entries < <(load_github_script_entries)

  if (( ${#entries[@]} == 0 )); then
    warn "GitHub 脚本索引为空。"
    echo
    echo "请在 GitHub 仓库创建：registry/scripts.conf"
    echo "格式：name|description|repo_path|runner|sha256_optional"
    echo "例子：bbr|开启 BBR|scripts/network/bbr.sh|bash|"
    pause
    return
  fi

  echo "GitHub 脚本列表："
  echo

  local i=1 line name desc path runner sha
  for line in "${entries[@]}"; do
    IFS='|' read -r name desc path runner sha <<< "$line"
    printf '  %2d) %-24s %s
' "$i" "$name" "$desc"
    ((i++))
  done

  echo "   0) 返回"
  echo

  local choice
  read -r -p "请选择：" choice

  if [[ "$choice" == "0" ]]; then
    return
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#entries[@]} )); then
    error "选择无效。"
    pause
    return
  fi

  line="${entries[$((choice-1))]}"
  IFS='|' read -r name desc path runner sha <<< "$line"

  run_one_script_entry "$name" "$desc" "$path" "$runner" "${sha:-}"
}

show_paths() {
  show_header
  echo "配置/路径："
  echo "------------------------------------------------------------"
  echo "GitHub Owner : $GITHUB_OWNER"
  echo "GitHub Repo  : $GITHUB_REPO"
  echo "GitHub Branch: $GITHUB_BRANCH"
  echo "Raw Base     : $GITHUB_RAW_BASE"
  echo "脚本索引     : $REMOTE_REGISTRY_URL"
  echo "日志文件     : $LOG_FILE"
  echo
  echo "registry/scripts.conf 格式："
  echo "  name|description|repo_path|runner|sha256_optional"
  echo
  echo "例子："
  echo "  bbr|开启 BBR|scripts/network/bbr.sh|bash|"
  echo "  nginx|安装 Nginx|scripts/app/install-nginx.sh|bash|"
  echo
  echo "注意：当前版本不读取本地脚本索引，也不保存远程索引缓存。"
  echo "每次进入脚本菜单都会实时从 GitHub 获取 registry/scripts.conf。"
  echo
  pause
}

main_menu() {
  while true; do
    show_header
    echo "  1) 查看系统信息"
    echo "  2) 更新系统软件包"
    echo "  3) 运行 GitHub 登记的脚本"
    echo "  4) 显示配置/路径"
    echo "  0) 退出"
    echo

    local choice
    read -r -p "请选择功能：" choice

    case "$choice" in
      1) os_info ;;
      2) update_system ;;
      3) run_registry_script ;;
      4) show_paths ;;
      0) exit 0 ;;
      *) warn "无效选择。"; sleep 1 ;;
    esac
  done
}

main() {
  need_root
  init_layout
  main_menu
}

main "$@"
