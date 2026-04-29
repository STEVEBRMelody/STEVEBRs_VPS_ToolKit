#!/usr/bin/env bash
# VPS All-in-One Toolkit
#
# Recommended GitHub repo structure:
#   your-repo/
#   ├── vpsctl.sh
#   ├── registry/
#   │   └── scripts.conf
#   └── scripts/
#       ├── ssh/change-port.sh
#       ├── network/bbr.sh
#       └── app/install-nginx.sh
#
# First-time usage after pushing to GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/vpsctl.sh)
#
# After installing as command:
#   vpsctl
#
# Important:
#   Edit GITHUB_OWNER and GITHUB_REPO below before pushing to your GitHub repo.

set -Eeuo pipefail

APP_NAME="vpsctl"
APP_VERSION="1.1.0"
APP_DIR="/opt/vpsctl"
CONFIG_DIR="/etc/vpsctl"
REGISTRY_FILE="$CONFIG_DIR/scripts.local.conf"
REMOTE_CACHE_FILE="$CONFIG_DIR/scripts.remote.cache"
MODULE_DIR="$CONFIG_DIR/modules.d"
LOG_FILE="/var/log/vpsctl.log"
TMP_DIR="/tmp/vpsctl.$$"

# ==================== GitHub remote script registry ====================
# Change these three lines in your GitHub copy.
# Then every VPS only needs to run the main script and choose menu items.
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

install_base_tools() {
  info "检查基础依赖 curl/wget/ca-certificates..."
  if command_exists apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget ca-certificates sudo lsof net-tools procps openssl
  elif command_exists dnf; then
    dnf install -y curl wget ca-certificates sudo lsof net-tools procps-ng openssl
  elif command_exists yum; then
    yum install -y curl wget ca-certificates sudo lsof net-tools procps-ng openssl
  elif command_exists apk; then
    apk add --no-cache curl wget ca-certificates sudo lsof net-tools procps openssl
  else
    warn "未识别包管理器，请手动确保 curl/wget/openssl 可用。"
  fi
}

init_layout() {
  mkdir -p "$APP_DIR" "$CONFIG_DIR" "$MODULE_DIR"
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

  if [[ ! -f "$MODULE_DIR/example.sh.disabled" ]]; then
    cat > "$MODULE_DIR/example.sh.disabled" <<'EOF'
# Local extension module example.
# Rename this file to example.sh and edit the function names to enable it.

module_name="Example local module"
module_description="This is an example local extension."

module_run() {
  echo "Hello from local module."
}
EOF
  fi
}

show_header() {
  clear || true
  echo "============================================================"
  echo " $APP_NAME $APP_VERSION - VPS All-in-One Toolkit"
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

get_sshd_config() {
  if [[ -f /etc/ssh/sshd_config ]]; then
    echo "/etc/ssh/sshd_config"
  elif [[ -f /etc/sshd/sshd_config ]]; then
    echo "/etc/sshd/sshd_config"
  else
    return 1
  fi
}

restart_sshd() {
  if command_exists systemctl; then
    if systemctl list-unit-files | grep -q '^sshd\.service'; then
      systemctl restart sshd
    elif systemctl list-unit-files | grep -q '^ssh\.service'; then
      systemctl restart ssh
    else
      systemctl restart sshd || systemctl restart ssh
    fi
  else
    service sshd restart || service ssh restart
  fi
}

open_firewall_port() {
  local port="$1"
  local proto="tcp"

  if command_exists ufw && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${port}/${proto}" || true
    success "已尝试通过 ufw 放行端口 $port/$proto。"
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/${proto}" || true
    firewall-cmd --reload || true
    success "已尝试通过 firewalld 放行端口 $port/$proto。"
  elif command_exists iptables; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
    warn "已临时添加 iptables 规则；如系统未配置持久化，重启后可能失效。"
  else
    warn "未发现 ufw/firewalld/iptables，请手动确认安全组和防火墙已放行端口 $port。"
  fi
}

change_ssh_port() {
  show_header
  local conf backup new_port current_port
  conf="$(get_sshd_config)" || {
    error "找不到 sshd_config。"
    pause
    return
  }

  current_port="$(grep -E '^#?Port[[:space:]]+' "$conf" | tail -n1 | awk '{print $2}' || true)"
  current_port="${current_port:-22}"

  echo "当前 SSH 配置文件：$conf"
  echo "当前检测到的端口：$current_port"
  echo
  warn "重要：改端口前，请确认云厂商安全组/防火墙已放行新端口。"
  read -r -p "请输入新的 SSH 端口，范围 1024-65535：" new_port

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1024 || new_port > 65535 )); then
    error "端口无效。"
    pause
    return
  fi

  if command_exists ss && ss -tuln | awk '{print $5}' | grep -Eq ":${new_port}$"; then
    error "端口 $new_port 似乎已被占用。"
    pause
    return
  fi

  echo
  echo "将把 SSH 端口从 $current_port 修改为 $new_port。"
  if ! confirm "确认继续？"; then
    warn "已取消。"
    pause
    return
  fi

  backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$conf" "$backup"
  info "已备份：$backup"

  if grep -Eq '^#?Port[[:space:]]+' "$conf"; then
    sed -i -E "s/^#?Port[[:space:]]+.*/Port ${new_port}/" "$conf"
  else
    printf '
Port %s
' "$new_port" >> "$conf"
  fi

  open_firewall_port "$new_port"

  if command_exists sshd; then
    if ! sshd -t -f "$conf"; then
      error "sshd 配置校验失败，正在回滚。"
      cp -a "$backup" "$conf"
      pause
      return
    fi
  else
    warn "未找到 sshd 命令，跳过配置校验。"
  fi

  if restart_sshd; then
    success "SSH 服务已重启。"
    echo
    warn "不要关闭当前 SSH 会话。请另开一个终端测试："
    echo "  ssh -p $new_port root@你的服务器IP"
    echo
    warn "确认新端口可登录后，再考虑关闭旧会话。"
  else
    error "SSH 服务重启失败，正在回滚。"
    cp -a "$backup" "$conf"
    restart_sshd || true
  fi
  pause
}

harden_ssh_basic() {
  show_header
  local conf backup
  conf="$(get_sshd_config)" || {
    error "找不到 sshd_config。"
    pause
    return
  }

  warn "此功能会做基础 SSH 加固：禁止空密码、禁止 ChallengeResponse、设置 MaxAuthTries。"
  warn "默认不会禁用 root 登录，避免把自己锁在门外。"
  if ! confirm "确认继续？"; then
    warn "已取消。"
    pause
    return
  fi

  backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$conf" "$backup"

  set_sshd_kv() {
    local key="$1" value="$2"
    if grep -Eiq "^#?${key}[[:space:]]+" "$conf"; then
      sed -i -E "s/^#?${key}[[:space:]]+.*/${key} ${value}/I" "$conf"
    else
      printf '
%s %s
' "$key" "$value" >> "$conf"
    fi
  }

  set_sshd_kv "PermitEmptyPasswords" "no"
  set_sshd_kv "KbdInteractiveAuthentication" "no"
  set_sshd_kv "PasswordAuthentication" "yes"
  set_sshd_kv "MaxAuthTries" "3"
  set_sshd_kv "ClientAliveInterval" "300"
  set_sshd_kv "ClientAliveCountMax" "2"

  if command_exists sshd && ! sshd -t -f "$conf"; then
    error "sshd 配置校验失败，正在回滚。"
    cp -a "$backup" "$conf"
    pause
    return
  fi

  restart_sshd && success "SSH 基础加固完成。备份文件：$backup" || error "SSH 重启失败。"
  pause
}

download_file() {
  local url="$1"
  local out="$2"
  if command_exists curl; then
    curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$out"
  elif command_exists wget; then
    wget -q --timeout=120 -O "$out" "$url"
  else
    error "curl/wget 不存在。"
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

add_registry_entry() {
  show_header
  echo "添加本地脚本登记"
  echo "保存到：$REGISTRY_FILE"
  echo
  local name desc path runner sha
  read -r -p "脚本名称，只允许字母数字下划线中划线：" name
  if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    error "名称无效。"
    pause
    return
  fi
  read -r -p "描述：" desc
  read -r -p "URL 或 GitHub 仓库内路径，例如 scripts/test.sh：" path
  if [[ -z "$path" ]]; then
    error "路径不能为空。"
    pause
    return
  fi
  if [[ "$path" =~ ^http:// ]]; then
    error "为安全起见，只接受 https URL，或填写 GitHub 仓库内相对路径。"
    pause
    return
  fi
  read -r -p "运行器 bash/sh/python3，默认 bash：" runner
  runner="${runner:-bash}"
  if [[ ! "$runner" =~ ^(bash|sh|python3)$ ]]; then
    error "不支持的运行器：$runner"
    pause
    return
  fi
  read -r -p "可选 SHA256，留空跳过校验：" sha
  if [[ -n "$sha" ]] && ! [[ "$sha" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    error "SHA256 格式无效。"
    pause
    return
  fi

  if grep -qE "^${name}\|" "$REGISTRY_FILE"; then
    error "名称已存在。请先手动编辑或删除旧条目。"
    pause
    return
  fi

  printf '%s|%s|%s|%s|%s
' "$name" "$desc" "$path" "$runner" "$sha" >> "$REGISTRY_FILE"
  success "已添加本地登记：$name"
  pause
}

edit_registry() {
  show_header
  local editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if command_exists nano; then
      editor="nano"
    elif command_exists vim; then
      editor="vim"
    elif command_exists vi; then
      editor="vi"
    else
      error "未找到 nano/vim/vi，请手动编辑：$REGISTRY_FILE"
      pause
      return
    fi
  fi
  "$editor" "$REGISTRY_FILE"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
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
  warn "风险提示：第三方脚本会以当前权限运行，可能修改系统、安装软件、删除文件或泄露信息。"
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
    echo "你可以在 GitHub 仓库创建：registry/scripts.conf"
    echo "格式：name|description|url_or_repo_path|runner|sha256_optional"
    echo "例子：bbr|Enable BBR|scripts/network/bbr.sh|bash|"
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

run_direct_repo_path_script() {
  show_header
  local path runner sha url file
  echo "这个功能不用输入完整下载链接，只输入 GitHub 仓库内路径即可。"
  echo "例如：scripts/network/bbr.sh"
  echo
  read -r -p "输入仓库内脚本路径：" path
  if [[ -z "$path" || "$path" =~ ^https?:// ]]; then
    error "这里只接受仓库内相对路径，不接受 URL。"
    pause
    return
  fi
  read -r -p "运行器 bash/sh/python3，默认 bash：" runner
  runner="${runner:-bash}"
  if [[ ! "$runner" =~ ^(bash|sh|python3)$ ]]; then
    error "不支持的运行器：$runner"
    pause
    return
  fi
  read -r -p "可选 SHA256，留空跳过校验：" sha

  url="$(resolve_repo_path "$path")"
  file="$TMP_DIR/direct-repo.script"
  echo "URL：$url"
  download_file "$url" "$file" || { error "下载失败。"; pause; return; }
  verify_sha256 "$file" "$sha" || { pause; return; }
  preview_file "$file"

  warn "这将以当前用户权限执行 GitHub 仓库里的脚本。"
  if ! confirm "确认执行？"; then
    warn "已取消。"
    pause
    return
  fi

  case "$runner" in
    bash) bash "$file" ;;
    sh) sh "$file" ;;
    python3) python3 "$file" ;;
  esac
  pause
}

run_local_modules() {
  show_header
  shopt -s nullglob
  local modules=("$MODULE_DIR"/*.sh)
  shopt -u nullglob

  if (( ${#modules[@]} == 0 )); then
    warn "没有启用的本地扩展模块。"
    echo
    echo "创建方式："
    echo "  1. 在 $MODULE_DIR 新建 xxx.sh"
    echo "  2. 文件里定义："
    echo "     module_name=\"我的模块\""
    echo "     module_description=\"描述\""
    echo "     module_run() { echo hello; }"
    echo
    pause
    return
  fi

  echo "本地扩展模块："
  echo
  local i=1 module_file module_name module_description
  for module_file in "${modules[@]}"; do
    module_name="$(bash -c "source '$module_file' >/dev/null 2>&1; echo \${module_name:-$(basename "$module_file")}" 2>/dev/null || basename "$module_file")"
    module_description="$(bash -c "source '$module_file' >/dev/null 2>&1; echo \${module_description:-}" 2>/dev/null || true)"
    printf '  %2d) %-28s %s
' "$i" "$module_name" "$module_description"
    ((i++))
  done
  echo "   0) 返回"
  echo

  local choice
  read -r -p "请选择：" choice
  [[ "$choice" == "0" ]] && return
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#modules[@]} )); then
    error "选择无效。"
    pause
    return
  fi

  module_file="${modules[$((choice-1))]}"
  echo "将执行本地模块：$module_file"
  if ! confirm "确认执行？"; then
    warn "已取消。"
    pause
    return
  fi

  # shellcheck source=/dev/null
  source "$module_file"
  if declare -F module_run >/dev/null; then
    module_run
  else
    error "模块未定义 module_run 函数。"
  fi
  pause
}

show_paths() {
  show_header
  echo "重要路径："
  echo "------------------------------------------------------------"
  echo "GitHub Owner     : $GITHUB_OWNER"
  echo "GitHub Repo      : $GITHUB_REPO"
  echo "GitHub Branch    : $GITHUB_BRANCH"
  echo "Raw Base         : $GITHUB_RAW_BASE"
  echo "远程脚本索引     : $REMOTE_REGISTRY_URL"
  echo "远程索引缓存     : $REMOTE_CACHE_FILE"
  echo "本地脚本注册表   : $REGISTRY_FILE"
  echo "本地模块目录     : $MODULE_DIR"
  echo "日志文件         : $LOG_FILE"
  echo
  echo "GitHub registry/scripts.conf 格式："
  echo "  name|description|url_or_repo_path|runner|sha256_optional"
  echo
  echo "例子："
  echo "  bbr|Enable BBR|scripts/network/bbr.sh|bash|"
  echo "  nginx|Install Nginx|scripts/app/install-nginx.sh|bash|"
  echo "  external|External HTTPS script|https://example.com/install.sh|bash|"
  echo
  echo "仓库内路径会自动转换为："
  echo "  ${GITHUB_RAW_BASE}/scripts/network/bbr.sh"
  echo
  pause
}

show_github_help() {
  show_header
  cat <<EOF
GitHub 托管模式说明
------------------------------------------------------------

你只需要在 GitHub 仓库维护这些文件：

  vpsctl.sh
  registry/scripts.conf
  scripts/ssh/change-port.sh
  scripts/network/bbr.sh
  scripts/app/install-nginx.sh

registry/scripts.conf 示例：

  ssh_port|修改 SSH 端口|scripts/ssh/change-port.sh|bash|
  bbr|开启 BBR|scripts/network/bbr.sh|bash|
  nginx|安装 Nginx|scripts/app/install-nginx.sh|bash|

VPS 上运行主脚本后，会自动拉取 registry/scripts.conf，菜单里显示这些脚本。
之后你新增功能时，只需要：

  1. 把新脚本 push 到 GitHub 的 scripts/ 目录
  2. 在 registry/scripts.conf 加一行
  3. VPS 上选择“同步 GitHub 脚本索引”或直接进入“运行脚本”

不需要在 VPS SSH 里手动输入每个脚本的下载链接。

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
    echo "  3) 修改 SSH 端口"
    echo "  4) SSH 基础加固"
    echo "  5) 运行 GitHub/本地登记的脚本"
    echo "  6) 同步 GitHub 脚本索引"
    echo "  7) 添加本地脚本登记"
    echo "  8) 编辑本地脚本注册表"
    echo "  9) 临时运行一个 GitHub 仓库内脚本路径"
    echo " 10) 运行本地扩展模块"
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
      3) change_ssh_port ;;
      4) harden_ssh_basic ;;
      5) run_registry_script ;;
      6) sync_remote_registry_menu ;;
      7) add_registry_entry ;;
      8) edit_registry ;;
      9) run_direct_repo_path_script ;;
      10) run_local_modules ;;
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
  install_base_tools
  init_layout
  main_menu
}

main "$@"
