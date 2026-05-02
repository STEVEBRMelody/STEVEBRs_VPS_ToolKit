#!/usr/bin/env bash
set -Eeuo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
BEGIN_MARK="# BEGIN VPSCTL MANAGED SSH PORT"
END_MARK="# END VPSCTL MANAGED SSH PORT"

SSHD_BIN=""
declare -a BACKUP_TARGETS=()
declare -a BACKUP_FILES=()

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
}

confirm() {
  local prompt="${1:-确认继续？}"
  local answer=""

  if [[ ! -t 0 ]]; then
    warn "当前不是交互式终端，无法确认：${prompt}"
    return 1
  fi

  read -r -p "${prompt} [y/N]: " answer
  [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "请使用 root 权限运行此脚本。"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
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
    return 1
  fi
}

install_package() {
  local mgr=""

  if ! mgr="$(detect_pkg_manager)"; then
    error "未识别到支持的包管理器：apt-get / dnf / yum / apk"
    return 1
  fi

  info "使用 ${mgr} 安装软件包：$*"

  case "${mgr}" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y || return 1
      apt-get install -y "$@" || return 1
      ;;
    dnf)
      dnf install -y "$@" || return 1
      ;;
    yum)
      yum install -y "$@" || return 1
      ;;
    apk)
      apk add --no-cache "$@" || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

find_sshd_bin() {
  if command_exists sshd; then
    command -v sshd
    return 0
  fi

  local candidate=""
  for candidate in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

ensure_sshd_available() {
  if SSHD_BIN="$(find_sshd_bin)"; then
    info "检测到 sshd：${SSHD_BIN}"
  else
    warn "未检测到 sshd，尝试自动安装 OpenSSH Server。"

    local mgr=""
    if ! mgr="$(detect_pkg_manager)"; then
      error "无法安装 OpenSSH Server：未识别到支持的包管理器。"
      return 1
    fi

    case "${mgr}" in
      apt-get|dnf|yum)
        install_package openssh-server || return 1
        ;;
      apk)
        install_package openssh || return 1
        ;;
      *)
        error "不支持的包管理器：${mgr}"
        return 1
        ;;
    esac

    if ! SSHD_BIN="$(find_sshd_bin)"; then
      error "OpenSSH Server 安装后仍未找到 sshd。"
      return 1
    fi

    success "OpenSSH Server 已安装。"
  fi

  if [[ ! -f "${SSHD_CONFIG}" ]]; then
    error "未找到 SSH 配置文件：${SSHD_CONFIG}"
    return 1
  fi
}

normalize_port() {
  local raw="$1"

  if ! [[ "${raw}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  printf '%d\n' "$((10#${raw}))"
}

validate_port() {
  local raw="$1"
  local port=""

  if ! port="$(normalize_port "${raw}")"; then
    error "端口必须是数字：${raw}"
    return 1
  fi

  if (( port < 1 || port > 65535 )); then
    error "端口范围必须是 1-65535，当前为：${port}"
    return 1
  fi

  if (( port < 1024 )); then
    warn "端口 ${port} 是特权端口，通常建议使用 1024-65535 之间的端口。"
  fi

  printf '%s\n' "${port}"
}

list_sshd_config_files() {
  if [[ -f "${SSHD_CONFIG}" ]]; then
    printf '%s\n' "${SSHD_CONFIG}"
  fi

  if [[ -d "${SSHD_CONFIG_D}" ]]; then
    shopt -s nullglob
    local file=""
    for file in "${SSHD_CONFIG_D}"/*.conf; do
      [[ -f "${file}" ]] && printf '%s\n' "${file}"
    done
    shopt -u nullglob
  fi
}

parse_configured_ports() {
  local file=""

  while IFS= read -r file; do
    awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2 }
    ' "${file}"
  done < <(list_sshd_config_files) | sort -n -u
}

get_effective_ports() {
  local ports=""

  if [[ -n "${SSHD_BIN}" ]]; then
    if ports="$("${SSHD_BIN}" -T -f "${SSHD_CONFIG}" 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -n -u)"; then
      if [[ -n "${ports}" ]]; then
        printf '%s\n' "${ports}"
        return 0
      fi
    fi
  fi

  ports="$(parse_configured_ports || true)"

  if [[ -n "${ports}" ]]; then
    printf '%s\n' "${ports}"
  else
    printf '22\n'
  fi
}

port_in_list() {
  local needle="$1"
  local list="$2"
  local item=""

  while IFS= read -r item; do
    [[ "${item}" == "${needle}" ]] && return 0
  done <<< "${list}"

  return 1
}

check_port_in_use() {
  local port="$1"
  local current_ports="$2"

  if port_in_list "${port}" "${current_ports}"; then
    return 0
  fi

  if command_exists ss; then
    if ss -ltn 2>/dev/null | awk -v port="${port}" '
      NR > 1 {
        if ($4 ~ "(^|[:.])" port "$") {
          found = 1
        }
      }
      END {
        exit found ? 0 : 1
      }
    '; then
      error "端口 ${port}/tcp 当前已被其他服务监听，请更换端口。"
      return 1
    fi
  elif command_exists netstat; then
    if netstat -ltn 2>/dev/null | awk -v port="${port}" '
      NR > 2 {
        if ($4 ~ "(^|[:.])" port "$") {
          found = 1
        }
      }
      END {
        exit found ? 0 : 1
      }
    '; then
      error "端口 ${port}/tcp 当前已被其他服务监听，请更换端口。"
      return 1
    fi
  else
    warn "未检测到 ss 或 netstat，无法自动检查端口占用。"
  fi
}

build_target_ports() {
  local new_port="$1"
  local keep_existing="$2"
  local current_ports="$3"

  {
    if [[ "${keep_existing}" == "1" ]]; then
      printf '%s\n' "${current_ports}"
    fi
    printf '%s\n' "${new_port}"
  } | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 { print $1 }' | sort -n -u
}

ports_to_space_list() {
  local ports="$1"
  local item=""
  local out=""

  while IFS= read -r item; do
    [[ -n "${item}" ]] && out="${out}${item} "
  done <<< "${ports}"

  printf '%s' "${out}"
}

format_ports() {
  local ports="$1"
  local item=""
  local out=""

  while IFS= read -r item; do
    [[ -n "${item}" ]] && out="${out}${item} "
  done <<< "${ports}"

  printf '%s\n' "${out% }"
}

backup_file() {
  local file="$1"
  local ts=""
  local backup=""

  ts="$(date +%Y%m%d%H%M%S)"
  backup="${file}.bak.${ts}"

  cp -p "${file}" "${backup}" || return 1

  BACKUP_TARGETS+=("${file}")
  BACKUP_FILES+=("${backup}")

  success "已备份：${file} -> ${backup}"
}

apply_file_if_changed() {
  local file="$1"
  local tmp="$2"

  if cmp -s "${file}" "${tmp}"; then
    info "配置无需变更：${file}"
  else
    backup_file "${file}" || return 1
    cat "${tmp}" > "${file}" || return 1
    success "已更新配置：${file}"
  fi

  if [[ -n "${tmp}" && -f "${tmp}" ]]; then
    rm -f "${tmp}"
  fi
}

rewrite_main_config() {
  local file="$1"
  local ports="$2"
  local ports_space=""
  local tmp=""

  ports_space="$(ports_to_space_list "${ports}")"
  tmp="$(mktemp)" || return 1

  awk \
    -v begin="${BEGIN_MARK}" \
    -v end="${END_MARK}" \
    -v ports="${ports_space}" '
    function print_block(   n, a, i) {
      print begin
      n = split(ports, a, " ")
      for (i = 1; i <= n; i++) {
        if (a[i] != "") {
          print "Port " a[i]
        }
      }
      print end
      print ""
    }

    $0 == begin {
      in_block = 1
      next
    }

    $0 == end {
      in_block = 0
      next
    }

    in_block {
      next
    }

    !inserted && $0 ~ /^[[:space:]]*Match[[:space:]]+/ {
      print_block()
      inserted = 1
    }

    {
      if ($0 !~ /^[[:space:]]*#/ && $0 ~ /^[[:space:]]*Port[[:space:]]+[0-9]+/) {
        print "# VPSCTL disabled old setting: " $0
      } else {
        print
      }
    }

    END {
      if (!inserted) {
        print ""
        print_block()
      }
    }
  ' "${file}" > "${tmp}"

  apply_file_if_changed "${file}" "${tmp}"
}

rewrite_dropin_config() {
  local file="$1"
  local tmp=""

  tmp="$(mktemp)" || return 1

  awk \
    -v begin="${BEGIN_MARK}" \
    -v end="${END_MARK}" '
    $0 == begin {
      in_block = 1
      next
    }

    $0 == end {
      in_block = 0
      next
    }

    in_block {
      next
    }

    {
      if ($0 !~ /^[[:space:]]*#/ && $0 ~ /^[[:space:]]*Port[[:space:]]+[0-9]+/) {
        print "# VPSCTL disabled old setting: " $0
      } else {
        print
      }
    }
  ' "${file}" > "${tmp}"

  apply_file_if_changed "${file}" "${tmp}"
}

rewrite_sshd_configs() {
  local target_ports="$1"
  local file=""

  rewrite_main_config "${SSHD_CONFIG}" "${target_ports}" || return 1

  if [[ -d "${SSHD_CONFIG_D}" ]]; then
    shopt -s nullglob
    for file in "${SSHD_CONFIG_D}"/*.conf; do
      [[ -f "${file}" ]] || continue
      rewrite_dropin_config "${file}" || return 1
    done
    shopt -u nullglob
  fi
}

rollback_configs() {
  local i=0

  if (( ${#BACKUP_FILES[@]} == 0 )); then
    return 0
  fi

  warn "正在回滚 SSH 配置文件。"

  for (( i=${#BACKUP_FILES[@]} - 1; i>=0; i-- )); do
    if [[ -f "${BACKUP_FILES[$i]}" ]]; then
      cp -p "${BACKUP_FILES[$i]}" "${BACKUP_TARGETS[$i]}" || return 1
      warn "已恢复：${BACKUP_TARGETS[$i]}"
    fi
  done
}

prepare_sshd_runtime_dir() {
  if [[ -d /run ]]; then
    mkdir -p /run/sshd
    chmod 0755 /run/sshd
  fi
}

test_sshd_config() {
  prepare_sshd_runtime_dir

  info "正在验证 SSH 配置。"

  if "${SSHD_BIN}" -t -f "${SSHD_CONFIG}"; then
    success "SSH 配置验证通过。"
    return 0
  fi

  error "SSH 配置验证失败。"
  return 1
}

install_semanage_tool() {
  local mgr=""

  if ! mgr="$(detect_pkg_manager)"; then
    return 1
  fi

  case "${mgr}" in
    apt-get)
      install_package policycoreutils-python-utils || install_package policycoreutils
      ;;
    dnf)
      install_package policycoreutils-python-utils
      ;;
    yum)
      install_package policycoreutils-python-utils || install_package policycoreutils-python
      ;;
    apk)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

configure_selinux() {
  local port="$1"
  local mode=""

  if ! command_exists getenforce; then
    return 0
  fi

  mode="$(getenforce 2>/dev/null || true)"

  if [[ -z "${mode}" || "${mode}" == "Disabled" ]]; then
    return 0
  fi

  info "检测到 SELinux 状态：${mode}"

  if ! command_exists semanage; then
    warn "未检测到 semanage，尝试安装 SELinux 管理工具。"
    if ! install_semanage_tool || ! command_exists semanage; then
      error "SELinux 已启用，但无法安装 semanage。请先放行 ssh_port_t 端口：${port}/tcp"
      return 1
    fi
  fi

  if semanage port -l 2>/dev/null | awk '$1 == "ssh_port_t" && $2 == "tcp" { for (i=3; i<=NF; i++) print $i }' | tr ',' '\n' | grep -qx "${port}"; then
    success "SELinux 已允许 SSH 使用端口 ${port}/tcp。"
    return 0
  fi

  info "正在为 SELinux 添加 ssh_port_t 端口：${port}/tcp"

  if semanage port -a -t ssh_port_t -p tcp "${port}" 2>/dev/null; then
    success "SELinux 已添加端口 ${port}/tcp。"
    return 0
  fi

  warn "新增 SELinux 端口失败，尝试修改已有端口类型为 ssh_port_t。"

  if semanage port -m -t ssh_port_t -p tcp "${port}" 2>/dev/null; then
    success "SELinux 已更新端口 ${port}/tcp。"
    return 0
  fi

  error "SELinux 端口配置失败：${port}/tcp"
  return 1
}

configure_firewall() {
  local port="$1"
  local handled=0

  if command_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    info "检测到 ufw 已启用，正在放行 ${port}/tcp。"
    if ufw allow "${port}/tcp"; then
      success "ufw 已放行 ${port}/tcp。"
      handled=1
    else
      error "ufw 放行 ${port}/tcp 失败。"
      return 1
    fi
  fi

  if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    info "检测到 firewalld 已启用，正在放行 ${port}/tcp。"
    if firewall-cmd --permanent --add-port="${port}/tcp" && firewall-cmd --reload; then
      success "firewalld 已放行 ${port}/tcp。"
      handled=1
    else
      error "firewalld 放行 ${port}/tcp 失败。"
      return 1
    fi
  fi

  if (( handled == 0 )); then
    warn "未检测到已启用的 ufw/firewalld，脚本未自动修改防火墙规则。"
  fi

  if command_exists iptables || command_exists nft; then
    warn "如果你使用 iptables/nftables 自定义规则，请确认已放行 ${port}/tcp。"
  fi

  warn "如果 VPS 云厂商有安全组/防火墙，请在控制台放行 ${port}/tcp。"
}

restart_ssh_service() {
  local svc=""

  if command_exists systemctl && [[ -d /run/systemd/system ]]; then
    for svc in sshd ssh; do
      if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
        info "正在重启 ${svc}.service。"
        systemctl enable "${svc}.service" >/dev/null 2>&1 || true

        if systemctl restart "${svc}.service"; then
          success "${svc}.service 已重启。"
          return 0
        fi

        error "${svc}.service 重启失败。"
        return 1
      fi
    done
  fi

  if command_exists rc-service; then
    for svc in sshd ssh; do
      if [[ -x "/etc/init.d/${svc}" ]]; then
        info "正在通过 OpenRC 重启 ${svc}。"
        rc-update add "${svc}" default >/dev/null 2>&1 || true

        if rc-service "${svc}" restart; then
          success "${svc} 已重启。"
          return 0
        fi

        error "${svc} 重启失败。"
        return 1
      fi
    done
  fi

  if command_exists service; then
    for svc in sshd ssh; do
      if service "${svc}" status >/dev/null 2>&1 || [[ -x "/etc/init.d/${svc}" ]]; then
        info "正在通过 service 重启 ${svc}。"

        if service "${svc}" restart; then
          success "${svc} 已重启。"
          return 0
        fi

        error "${svc} 重启失败。"
        return 1
      fi
    done
  fi

  for svc in sshd ssh; do
    if [[ -x "/etc/init.d/${svc}" ]]; then
      info "正在通过 /etc/init.d/${svc} 重启 SSH。"

      if "/etc/init.d/${svc}" restart; then
        success "${svc} 已重启。"
        return 0
      fi

      error "${svc} 重启失败。"
      return 1
    fi
  done

  error "未能找到可用的 SSH 服务管理方式。"
  return 1
}

main() {
  need_root

  local new_port=""
  local normalized_port=""
  local replace_mode=0
  local replace_mode_set=0
  local assume_yes=0
  local current_ports=""
  local target_ports=""
  local keep_existing=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --replace)
        replace_mode=1
        replace_mode_set=1
        ;;
      --yes)
        assume_yes=1
        ;;
      *)
        if [[ -z "${new_port}" ]]; then
          new_port="$1"
        else
          error "未知参数：$1"
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [[ -z "${new_port}" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "请输入新的 SSH 端口，例如 2222: " new_port
    else
      error "未提供新端口。"
      exit 1
    fi
  fi

  normalized_port="$(validate_port "${new_port}")" || exit 1
  new_port="${normalized_port}"

  ensure_sshd_available || exit 1

  current_ports="$(get_effective_ports)"
  info "当前识别到的 SSH 端口：$(format_ports "${current_ports}")"

  check_port_in_use "${new_port}" "${current_ports}" || exit 1

  if (( replace_mode_set == 0 )); then
    warn "安全模式会保留旧 SSH 端口，避免新端口未放行时失联。"
    warn "replace 模式会关闭旧 SSH 端口，只保留新端口，风险更高。"

    if (( assume_yes == 0 )) && [[ -t 0 ]]; then
      if confirm "是否启用 replace 模式，只保留新端口 ${new_port}/tcp？"; then
        replace_mode=1
      else
        replace_mode=0
      fi
    else
      replace_mode=0
    fi
  fi

  if (( replace_mode == 1 )); then
    keep_existing=0
    warn "当前选择：replace 模式，只保留 ${new_port}/tcp。"
    warn "如果新端口未被系统防火墙、云安全组或 SELinux 放行，你可能会失去 SSH 连接。"
  else
    keep_existing=1
    warn "当前选择：安全模式，保留旧 SSH 端口，并新增 ${new_port}/tcp。"
  fi

  target_ports="$(build_target_ports "${new_port}" "${keep_existing}" "${current_ports}")"
  info "目标 SSH 监听端口：$(format_ports "${target_ports}")"

  if (( assume_yes == 0 )); then
    confirm "确认修改 SSH 配置并重启 SSH 服务？" || {
      warn "用户取消操作。"
      exit 0
    }
  fi

  configure_firewall "${new_port}" || exit 1
  configure_selinux "${new_port}" || exit 1

  rewrite_sshd_configs "${target_ports}" || {
    error "写入 SSH 配置失败。"
    rollback_configs || true
    exit 1
  }

  if ! test_sshd_config; then
    rollback_configs || true
    test_sshd_config || true
    exit 1
  fi

  if ! restart_ssh_service; then
    error "SSH 服务重启失败，正在尝试回滚配置。"
    rollback_configs || true
    test_sshd_config || true
    restart_ssh_service || true
    exit 1
  fi

  success "SSH 端口配置完成。"
  info "当前目标 SSH 端口：$(format_ports "${target_ports}")"
  info "请使用新终端测试连接，例如：ssh -p ${new_port} root@你的服务器IP"

  if (( keep_existing == 1 )); then
    warn "旧 SSH 端口仍保留作为回退。确认 ${new_port}/tcp 可正常登录后，可再次运行脚本并在交互中选择 replace 模式。"
  fi
}

main "$@"
