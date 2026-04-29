#!/usr/bin/env bash
# VPS All-in-One Toolkit - Lite
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
APP_VERSION="1.2.0-lite"
CONFIG_DIR="/etc/vpsctl"
REGISTRY_FILE="$CONFIG_DIR/scripts.local.conf"
REMOTE_CACHE_FILE="$CONFIG_DIR/scripts.remote.cache"
LOG_FILE="/var/log/vpsctl.log"
TMP_DIR="/tmp/vpsctl.$$"

# ==================== GitHub remote script registry ====================
GITHUB_OWNER="${VPSCTL_GITHUB_OWNER:-YOUR_NAME}"
GITHUB_REPO="${VPSCTL_GITHUB_REPO:-YOUR_REPO}"
GITHUB_BRANCH="${VPSCTL_GITHUB_BRANCH:-main}"

GITHUB_RAW_BASE="${VPSCTL_GITHUB_RAW_BASE:-https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_BRANCH}}"
REMOTE_REGISTRY_URL="${VPSCTL_REMOTE_REGISTRY_URL:-${GITHUB_RAW_BASE}/registry/scripts.conf}"
USE_REMOTE_REGISTRY="${VPSCTL_USE_REMOTE_REGISTRY:-1}"
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

info() { echo -e "${BLUE}[INFO]${NC} $*"; log INFO "$*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; log OK "$*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; log WARN "$*"; }
error() { echo -e "${RED}[ERR]${NC} $*"; log ERROR "$*"; }

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

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    cat > "$REGISTRY_FILE" <<'EOF'
# Local-only script registry.
# Remote GitHub registry path: registry/scripts.conf
# Format:
#   name|description|url_or_repo_path|runner|sha256_optional
#
# url_or_repo_path:
#   - scripts/example.sh       means GitHub raw path under your repo
#   - https://example.com/x.sh means external HTTPS URL
#
# runner supports: bash, sh, python3
# Example:
#   local_example|Example safe script|scripts/example.sh|bash|
EOF
    chmod 600 "$REGISTRY_FILE"
  fi
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

is_url() {
  [[ "$1" =~ ^https:// ]]
}

resolve_repo_path() {
  local value="$1"
  if is_url "$value"; then
    echo "$value"
  else
    value="${value#/}"
    echo "${GITHUB_RAW_BASE}/${value}"
  fi
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

fetch_remote_registry() {
  [[ "$USE_REMOTE_REGISTRY" == "1" ]] || return 1

  if [[ "$GITHUB_OWNER" == "YOUR_NAME" || "$GITHUB_REPO" == "YOUR_REPO" ]]; then
    warn "GitHub 仓库尚未配置。请先编辑脚本顶部的 GITHUB_OWNER/GITHUB_REPO。"
    return 1
  fi

  info "正在同步 GitHub 脚本索引：$REMOTE_REGISTRY_URL"
  local tmp="$TMP_DIR/scripts.remote.conf"

  if download_file "$REMOTE_REGISTRY_URL" "$tmp"; then
    cp -a "$tmp" "$REMOTE_CACHE_FILE"
    chmod 600 "$REMOTE_CACHE_FILE"
    success "GitHub 脚本索引同步完成。"
    return 0
  fi

  warn "远程索引同步失败。"
  if [[ -s "$REMOTE_CACHE_FILE" ]]; then
    warn "将使用上次缓存：$REMOTE_CACHE_FILE"
    return 0
  fi

  return 1
}

sync_remote_registry_menu() {
  show_header
  if fetch_remote_registry; then
    echo
    echo "已缓存到：$REMOTE_CACHE_FILE"
    echo
    echo "当前远程脚本："
    echo "------------------------------------------------------------"
    list_registry_entries "github" "$REMOTE_CACHE_FILE" | awk -F'|' '{printf "  %-20s %s
", $2, $3}' || true
  else
    error "同步失败。请检查 GitHub 配置、仓库是否公开，或 raw 地址是否可访问。"
  fi
  pause
}

list_registry_entries() {
  local source_name="$1"
  local file_path="$2"

  [[ -s "$file_path" ]] || return 0

  awk -v src="$source_name" '
    BEGIN { FS="|" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF >= 4 { print src "|" $0 }
  ' "$file_path"
}

load_all_script_entries() {
  if [[ "$USE_REMOTE_REGISTRY" == "1" ]]; then
    fetch_remote_registry >/dev/null 2>&1 || true
    list_registry_entries "github" "$REMOTE_CACHE_FILE"
  fi

  list_registry_entries "local" "$REGISTRY_FILE"
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
  local source name desc path runner sha url file

  source="$1"
  name="$2"
  desc="$3"
  path="$4"
  runner="$5"
  sha="${6:-}"
  url="$(resolve_repo_path "$path")"

  echo
  echo "来源：$source"
  echo "名称：$name"
  echo "描述：$desc"
  echo "路径：$path"
  echo "URL ：$url"
  echo "运行器：$runner"
  echo "SHA256：${sha:-未设置}"
  echo
  warn "风险提示：脚本会以 root 权限运行，请确认来源可信。"

  if ! confirm "是否下载并预览？"; then
    warn "已取消。"
    pause
    return
  fi

  file="$TMP_DIR/${name}.script"
  info "正在下载..."
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

  mapfile -t entries < <(load_all_script_entries)

  if (( ${#entries[@]} == 0 )); then
    warn "暂无可用脚本。"
    echo
    echo "请在 GitHub 仓库创建：registry/scripts.conf"
    echo "格式：name|description|url_or_repo_path|runner|sha256_optional"
    echo "例子：bbr|开启 BBR|scripts/network/bbr.sh|bash|"
    pause
    return
  fi

  echo "脚本列表："
  echo

  local i=1 line source name desc path runner sha
  for line in "${entries[@]}"; do
    IFS='|' read -r source name desc path runner sha <<< "$line"
    printf '  %2d) [%s] %-24s %s
' "$i" "$source" "$name" "$desc"
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
  IFS='|' read -r source name desc path runner sha <<< "$line"

  run_one_script_entry "$source" "$name" "$desc" "$path" "$runner" "${sha:-}"
}

show_paths() {
  show_header
  echo "配置/路径："
  echo "------------------------------------------------------------"
  echo "GitHub Owner   : $GITHUB_OWNER"
  echo "GitHub Repo    : $GITHUB_REPO"
  echo "GitHub Branch  : $GITHUB_BRANCH"
  echo "Raw Base       : $GITHUB_RAW_BASE"
  echo "远程脚本索引   : $REMOTE_REGISTRY_URL"
  echo "远程索引缓存   : $REMOTE_CACHE_FILE"
  echo "本地脚本注册表 : $REGISTRY_FILE"
  echo "日志文件       : $LOG_FILE"
  echo
  echo "registry/scripts.conf 格式："
  echo "  name|description|url_or_repo_path|runner|sha256_optional"
  echo
  echo "例子："
  echo "  bbr|开启 BBR|scripts/network/bbr.sh|bash|"
  echo "  nginx|安装 Nginx|scripts/app/install-nginx.sh|bash|"
  echo
  pause
}

show_github_help() {
  show_header
  cat <<EOF
GitHub 托管模式说明
------------------------------------------------------------

仓库推荐结构：

  vpsctl.sh
  registry/scripts.conf
  scripts/network/bbr.sh
  scripts/app/install-nginx.sh

registry/scripts.conf 示例：

  bbr|开启 BBR|scripts/network/bbr.sh|bash|
  nginx|安装 Nginx|scripts/app/install-nginx.sh|bash|

新增脚本流程：

  1. 把脚本放到 GitHub 仓库的 scripts/ 目录
  2. 在 registry/scripts.conf 加一行
  3. VPS 上选择“同步 GitHub 脚本索引”或直接进入“运行 GitHub/本地登记的脚本”

当前远程索引：
  $REMOTE_REGISTRY_URL

EOF
  pause
}

install_self_command() {
  show_header

  local src target
  src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  target="/usr/local/bin/vpsctl"

  if [[ ! -f "$src" ]]; then
    error "无法定位当前脚本文件。通过 bash <(curl ...) 运行时不能自安装，请先下载到本地再执行。"
    echo
    echo "推荐："
    echo "  curl -fsSL -o vpsctl.sh ${GITHUB_RAW_BASE}/vpsctl.sh"
    echo "  sudo bash vpsctl.sh"
    pause
    return
  fi

  cp -a "$src" "$target"
  chmod +x "$target"

  success "已安装命令：$target"
  echo "以后可直接运行：vpsctl"
  pause
}

main_menu() {
  while true; do
    show_header
    echo "  1) 查看系统信息"
    echo "  2) 更新系统软件包"
    echo "  5) 运行 GitHub/本地登记的脚本"
    echo "  6) 同步 GitHub 脚本索引"
    echo " 11) 显示配置/扩展路径"
    echo " 12) GitHub 托管模式说明"
    echo " 13) 安装 vpsctl 命令到 /usr/local/bin"
    echo "  0) 退出"
    echo

    local choice
    read -r -p "请选择功能：" choice

    case "$choice" in
      1) os_info ;;
      2) update_system ;;
      5) run_registry_script ;;
      6) sync_remote_registry_menu ;;
      11) show_paths ;;
      12) show_github_help ;;
      13) install_self_command ;;
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
