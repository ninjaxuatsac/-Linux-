#!/usr/bin/env bash
# universal_optimize.sh
# 通用 Linux 网络/内核安全优化（仅系统层；不改应用/防火墙）
# 适配：Debian/Ubuntu、RHEL/CentOS/Alma/Rocky、openSUSE、Alpine，以及常见云厂商
# 设计目标：一次执行 -> 立即生效 + 尽量持久化；出错不终止（降级兜底）

set -euo pipefail
umask 022

ACTION="${1:-apply}"     # apply | status | repair
LOG_PREFIX="[universal-optimize]"
SYSCTL_FILE="/etc/sysctl.d/99-universal-net.conf"
UNIT_NAME="univ-offload@.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
HELPER="/usr/local/sbin/univ-disable-offloads"
DEFAULT_IFACE=""

log()   { printf "%s %s\n" "$LOG_PREFIX" "$*"; }
ok()    { printf "\033[32m%s %s\033[0m\n" "$LOG_PREFIX" "$*"; }
warn()  { printf "\033[33m%s %s\033[0m\n" "$LOG_PREFIX" "$*"; }
err()   { printf "\033[31m%s %s\033[0m\n" "$LOG_PREFIX" "$*"; }

is_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_iface() {
  # 1) 走默认路由网卡
  if is_cmd ip; then
    local dev
    dev="$(ip -o route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    if [[ -n "${dev:-}" ]]; then DEFAULT_IFACE="$dev"; return 0; fi
  fi
  # 2) 退化到第一个非 lo 网卡
  if is_cmd ip; then
    local first
    first="$(ip -o link 2>/dev/null | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|veth|br-|virbr|tun|tap)' | head -n1 || true)"
    if [[ -n "${first:-}" ]]; then DEFAULT_IFACE="$first"; return 0; fi
  fi
  # 3) 还不行就尝试常见命名
  for n in eth0 ens3 enp1s0; do
    if [[ -e "/sys/class/net/$n" ]]; then DEFAULT_IFACE="$n"; return 0; fi
  done
  return 1
}

pkg_install() {
  # 尽量静默安装依赖：iproute2（通常已自带）、ethtool、grep、awk 等
  local need=()
  is_cmd ip       || need+=("iproute2")  # RHEL系叫 iproute
  is_cmd ethtool  || need+=("ethtool")
  [[ ${#need[@]} -eq 0 ]] && return 0

  if is_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends ethtool iproute2 >/dev/null 2>&1 || true
    return 0
  fi
  if is_cmd dnf; then
    dnf install -y ethtool iproute >/dev/null 2>&1 || true
    return 0
  fi
  if is_cmd yum; then
    yum install -y ethtool iproute >/dev/null 2>&1 || true
    return 0
  fi
  if is_cmd zypper; then
    zypper -n in ethtool iproute2 >/dev/null 2>&1 || true
    return 0
  fi
  if is_cmd apk; then
    apk add --no-progress ethtool iproute2 >/dev/null 2>&1 || true
    return 0
  fi
  warn "未找到可用包管理器，跳过自动安装依赖（若缺少 ethtool 将降级处理）"
}

max_val() {
  # echo max(a, b)
  local a="$1" b="$2"
  if (( a > b )); then echo "$a"; else echo "$b"; fi
}

apply_sysctl_safe() {
  # 只“抬高”默认缓冲/UDP三元组，不降低现有更高值；不触碰 rmem_max/wmem_max/tcp 拥塞算法等
  local rdef_now wdef_now opt_now u1 u2 u3
  rdef_now="$(sysctl -n net.core.rmem_default 2>/dev/null || echo 212992)"
  wdef_now="$(sysctl -n net.core.wmem_default 2>/dev/null || echo 212992)"
  opt_now="$(sysctl -n net.core.optmem_max   2>/dev/null || echo 10240)"
  read -r u1 u2 u3 <<<"$(sysctl -n net.ipv4.udp_mem 2>/dev/null || echo '0 0 0')"

  # 目标（以 4K页为例：32/64/128MB）
  local rdef_t=4194304 wdef_t=4194304 opt_t=8388608
  local u1_t=8192 u2_t=16384 u3_t=32768

  local rdef_new wdef_new opt_new u1_new u2_new u3_new
  rdef_new="$(max_val "$rdef_now" "$rdef_t")"
  wdef_new="$(max_val "$wdef_now" "$wdef_t")"
  opt_new="$(max_val "$opt_now"  "$opt_t")"

  # 如果当前 udp_mem 未取到，按目标写
  if [[ -z "${u1:-}" || -z "${u2:-}" || -z "${u3:-}" ]]; then
    u1_new="$u1_t"; u2_new="$u2_t"; u3_new="$u3_t"
  else
    u1_new="$(max_val "$u1" "$u1_t")"
    u2_new="$(max_val "$u2" "$u2_t")"
    u3_new="$(max_val "$u3" "$u3_t")"
  fi

  cat >"$SYSCTL_FILE" <<CONF
# 由 universal_optimize.sh 生成（安全、保守，不覆盖更高阈值）
net.core.rmem_default = $rdef_new
net.core.wmem_default = $wdef_new
net.core.optmem_max   = $opt_new
# UDP 阈值（页）：约 32MB/64MB/128MB（假设 4K 页）
net.ipv4.udp_mem      = $u1_new $u2_new $u3_new
# 轻量系统项，不影响稳定性
vm.swappiness = 10
fs.file-max   = $(max_val "$(sysctl -n fs.file-max 2>/dev/null || echo 100000)" 2097152)
CONF

  sysctl --system >/dev/null 2>&1 || true
  ok "sysctl 已应用并持久化：$SYSCTL_FILE"
}

write_helper_script() {
  # 运行一次关 offload（忽略失败），并支持 @reboot / udev 调用
  cat >"$HELPER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFACE="${1:-}"
[[ -z "$IFACE" ]] && exit 0
ET="$(command -v ethtool || echo /sbin/ethtool)"
# 尽可能关闭（不支持/失败都忽略）
$ET -K "$IFACE" gro off gso off tso off lro off scatter-gather off rx-gro-hw off 2>/dev/null || true
exit 0
SH
  chmod +x "$HELPER"
}

write_systemd_unit() {
  # oneshot + RemainAfterExit；所有失败都被忽略（前缀 -）
  cat >"$UNIT_PATH" <<'UNIT'
[Unit]
Description=Disable NIC offloads for %i (universal-safe)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/sys/class/net/%i

[Service]
Type=oneshot
# 等链路 UP 最多 10 秒
ExecStartPre=/bin/sh -c 'for i in $(seq 1 20); do ip link show %i 2>/dev/null | grep -q "state UP" && exit 0; sleep 0.5; done; exit 0'
ExecStart=-/usr/local/sbin/univ-disable-offloads %i
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload || true
}

enable_offload_persist() {
  local iface="$1"
  if is_cmd systemctl && systemctl >/dev/null 2>&1; then
    systemctl enable --now "univ-offload@${iface}.service" >/dev/null 2>&1 || true
    # 验证执行态（oneshot 执行成功会是 active (exited)）
    if systemctl is-active "univ-offload@${iface}.service" >/dev/null 2>&1; then
      ok "systemd 持久化 offload 关闭：univ-offload@${iface}.service"
      return 0
    fi
    warn "systemd 单元未处于 active 状态，但已尝试执行（后备方案将启用）"
  else
    warn "未检测到 systemd，启用后备持久化方案"
  fi

  # 后备1：@reboot 任务（如果有 cron）
  if is_cmd crontab; then
    local line="@reboot $HELPER ${iface} >/dev/null 2>&1 || true"
    (crontab -l 2>/dev/null | grep -v "$HELPER" ; echo "$line") | crontab - || true
    ok "已写入 root 的 @reboot 任务作为持久化后备"
    return 0
  fi

  # 后备2：rc.local（为 systemd 创建 rc-local.service）
  if [[ ! -f /etc/rc.local ]]; then
    cat >/etc/rc.local <<'RC'
#!/bin/sh -e
exit 0
RC
    chmod +x /etc/rc.local
  fi
  if ! grep -q "$HELPER" /etc/rc.local; then
    sed -i "s|^exit 0|$HELPER ${iface} >/dev/null 2>\&1 || true\nexit 0|" /etc/rc.local
  fi
  if is_cmd systemctl; then
    # 有些系统没有默认的 rc-local.service
    if [[ ! -f /etc/systemd/system/rc-local.service && ! -f /lib/systemd/system/rc-local.service ]]; then
      cat >/etc/systemd/system/rc-local.service <<'UNIT'
[Unit]
Description=/etc/rc.local Compatibility
After=network.target

[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
RemainAfterExit=yes
GuessMainPID=no

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload || true
    fi
    systemctl enable --now rc-local.service >/dev/null 2>&1 || true
  fi
  ok "rc.local 持久化后备已启用"
}

apply_now_once() {
  local iface="$1"
  if [[ -z "$iface" || ! -e "/sys/class/net/$iface" ]]; then
    warn "未找到有效网卡，跳过即时 offload 关闭"
    return 0
  fi
  "$HELPER" "$iface" || true
  ok "已对 $iface 进行一次性 offload 关闭尝试"
}

show_status() {
  local iface="$1"
  echo "=== 状态报告 ($(date '+%F %T')) ==="
  echo "- 目标网卡：${iface:-<未检测到>}"
  echo "- sysctl 文件：$SYSCTL_FILE"
  if [[ -f "$SYSCTL_FILE" ]]; then
    sysctl -n net.core.rmem_default net.core.wmem_default net.core.optmem_max \
      net.ipv4.udp_mem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min 2>/dev/null | nl -ba
  else
    warn "未找到 $SYSCTL_FILE（可执行 repair）"
  fi
  echo
  if [[ -n "${iface:-}" && -e "/sys/class/net/$iface" ]]; then
    if is_cmd ethtool; then
      ethtool -k "$iface" 2>/dev/null | egrep -i 'gro|gso|tso|lro|scatter-gather' | sed -n '1,40p' || true
    else
      warn "缺少 ethtool，无法显示 offload 状态"
    fi
    echo
    if is_cmd systemctl; then
      systemctl is-enabled "univ-offload@${iface}.service" >/dev/null 2>&1 && \
        echo "univ-offload@${iface}.service: enabled" || echo "univ-offload@${iface}.service: not-enabled"
      systemctl is-active  "univ-offload@${iface}.service" >/dev/null 2>&1 && \
        echo "univ-offload@${iface}.service: active"  || echo "univ-offload@${iface}.service: inactive"
    fi
  else
    warn "未检测到有效网卡，无法展示 offload 状态"
  fi
}

apply_all() {
  pkg_install
  detect_iface || { err "无法探测网卡；请传参：IFACE=xxx bash universal_optimize.sh apply"; exit 0; }
  local iface="${IFACE:-$DEFAULT_IFACE}"

  apply_sysctl_safe
  write_helper_script
  write_systemd_unit
  enable_offload_persist "$iface"
  apply_now_once "$iface"
  show_status "$iface"
}

repair_missing() {
  pkg_install
  detect_iface || { warn "无法探测网卡"; }
  local iface="${IFACE:-$DEFAULT_IFACE}"

  [[ -x "$HELPER" ]]     || write_helper_script
  [[ -f "$UNIT_PATH" ]]  || write_systemd_unit
  [[ -f "$SYSCTL_FILE" ]]|| apply_sysctl_safe

  if [[ -n "${iface:-}" ]]; then
    enable_offload_persist "$iface"
    apply_now_once "$iface"
  fi
  show_status "$iface"
}

case "$ACTION" in
  apply)  apply_all ;;
  repair) repair_missing ;;
  status) detect_iface || true; show_status "${IFACE:-$DEFAULT_IFACE}" ;;
  *) echo "用法: bash universal_optimize.sh [apply|status|repair]  (默认 apply)"; exit 0;;
esac
