#!/usr/bin/env bash
set -Eeuo pipefail

info() {
  echo "[INFO] $*"
}

success() {
  echo "[OK] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

error() {
  echo "[ERR] $*" >&2
  exit 1
}

confirm() {
  local prompt="${1:-确认继续？}"
  local answer=""

  read -r -p "[WARN] ${prompt} [y/N]: " answer || true
  case "${answer}" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "此脚本需要 root 权限运行，请使用 root 用户或 sudo。"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

backup_file() {
  local file="$1"
  local ts=""

  ts="$(date '+%Y%m%d%H%M%S')"

  if [[ -f "${file}" ]]; then
    cp -a "${file}" "${file}.bak.${ts}"
    success "已备份：${file}.bak.${ts}"
  else
    warn "${file} 不存在，将创建新文件。"
  fi
}

write_sysctl_config() {
  local config_file="/etc/sysctl.conf"
  local tmp_file=""
  local begin_marker="# BEGIN VPSCTL TCP SYSCTL TUNING"
  local end_marker="# END VPSCTL TCP SYSCTL TUNING"

  tmp_file="$(mktemp)"

  if [[ -f "${config_file}" ]]; then
    awk -v begin="${begin_marker}" -v end="${end_marker}" '
      BEGIN { skip = 0 }
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      skip == 1 { next }
      $0 ~ /^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/ { next }
      $0 ~ /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/ { next }
      $0 ~ /^[[:space:]]*net\.ipv4\.tcp_collapse_max_bytes[[:space:]]*=/ { next }
      $0 ~ /^[[:space:]]*net\.ipv4\.tcp_slow_start_after_idle[[:space:]]*=/ { next }
      $0 ~ /^[[:space:]]*net\.ipv4\.tcp_rmem[[:space:]]*=/ { next }
      $0 ~ /^[[:space:]]*net\.ipv4\.tcp_wmem[[:space:]]*=/ { next }
      { print }
    ' "${config_file}" > "${tmp_file}"
  fi

  {
    echo ""
    echo "${begin_marker}"
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
    echo "net.ipv4.tcp_collapse_max_bytes = 1"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo "net.ipv4.tcp_rmem = 4096 87380 33554432"
    echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
    echo "${end_marker}"
  } >> "${tmp_file}"

  cat "${tmp_file}" > "${config_file}"
  rm -f "${tmp_file}"

  success "已写入 TCP sysctl 配置：${config_file}"
}

apply_sysctl_config() {
  local config_file="/etc/sysctl.conf"

  if command_exists sysctl; then
    info "正在应用 sysctl 配置..."
    if sysctl -p "${config_file}"; then
      success "sysctl 配置已生效。"
    else
      warn "sysctl -p 执行失败。可能是当前内核不支持 BBR、fq 或某些 TCP 参数，请检查上方输出。"
      return 1
    fi
  else
    warn "未找到 sysctl 命令，已写入配置文件，但暂未即时应用。重启后可能生效。"
  fi
}

main() {
  local assume_yes="false"

  if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
    assume_yes="true"
  fi

  need_root

  info "此脚本将修改 /etc/sysctl.conf，并写入 TCP、BBR、fq 参数优化配置。"

  if [[ "${assume_yes}" != "true" ]]; then
    confirm "修改系统网络参数可能影响当前 TCP 连接，确认继续？" || error "用户取消操作。"
  fi

  backup_file "/etc/sysctl.conf"
  write_sysctl_config
  apply_sysctl_config || true

  success "操作完成。"
}

main "$@"
