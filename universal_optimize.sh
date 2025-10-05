#!/usr/bin/env bash
# ==========================================================
# Universal Linux Optimize - 安全通用优化终极版 (手机端可直接运行)
# 支持 Debian/Ubuntu/CentOS/KVM/XanMod/BareMetal
# 包含 sysctl 优化 + offload 禁用 + IRQ绑定 + 自检 + 持久化
# 不动防火墙、不动代理配置、不影响业务。
# ==========================================================

set -euo pipefail
ACTION="${1:-apply}"
SELF="/usr/local/sbin/universal-optimize"

SYSCTL_FILE="/etc/sysctl.d/99-universal-optimize.conf"
OFFLOAD_UNIT="/etc/systemd/system/net-offload@.service"
IRQPIN_UNIT="/etc/systemd/system/net-irqpin@.service"
HEALTH_UNIT="/etc/systemd/system/sys-guard-health.service"

ok(){ echo -e "\033[32m$*\033[0m"; }
warn(){ echo -e "\033[33m$*\033[0m"; }

detect_iface() {
  IFACE="$(ip -o route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  [[ -z "${IFACE:-}" ]] && IFACE="$(ls /sys/class/net | grep -v lo | head -n1)"
  [[ -z "${IFACE:-}" ]] && { echo "[ERR] 无法探测网卡"; exit 1; }
}

apply_sysctl() {
cat >"$SYSCTL_FILE" <<'CONF'
# ---- 通用安全 sysctl 优化 ----
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.core.optmem_max   = 16777216
net.ipv4.udp_mem      = 16384 32768 65536
net.ipv4.udp_rmem_min = 262144
net.ipv4.udp_wmem_min = 262144
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_max_syn_backlog = 65535
net.core.somaxconn = 65535
fs.file-max = 4194304
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
CONF
sysctl --system >/dev/null 2>&1 || true
ok "[sysctl] 已持久化安全优化"
}

apply_offload() {
cat >"$OFFLOAD_UNIT" <<'UNIT'
[Unit]
Description=Disable NIC offloads for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=-/bin/bash -lc 'ethtool -K %i gro off gso off tso off lro off scatter-gather off rx-gro-hw off 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "net-offload@${IFACE}.service" >/dev/null 2>&1 || true
systemctl restart "net-offload@${IFACE}.service" || true
ok "[offload] 禁用网络硬件加速并开机自启"
}

apply_irqpin() {
cat >"$IRQPIN_UNIT" <<'UNIT'
[Unit]
Description=Pin NIC IRQs of %i to CPU0
After=network.target

[Service]
Type=oneshot
ExecStart=-/bin/bash -lc '
  IF="%i"
  IRQ=$(cat /sys/class/net/$IF/device/irq 2>/dev/null || true)
  [[ -n "$IRQ" ]] && echo 1 > /proc/irq/$IRQ/smp_affinity 2>/dev/null && echo "[irq] IRQ $IRQ 绑定 CPU0"
  for f in /sys/class/net/$IF/device/msi_irqs/*; do
    [[ -f "$f" ]] || continue
    irq=$(basename "$f")
    echo 1 > /proc/irq/$irq/smp_affinity 2>/dev/null && echo "[irq] MSI IRQ $irq 绑定 CPU0"
  done
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "net-irqpin@${IFACE}.service" >/dev/null 2>&1 || true
systemctl restart "net-irqpin@${IFACE}.service" || true
ok "[irqpin] IRQ 优化服务配置完成"
}

apply_health_check() {
cat >"$HEALTH_UNIT" <<UNIT
[Unit]
Description=Universal Optimize Health Check
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'sleep 5; "$SELF" status'

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable sys-guard-health.service >/dev/null 2>&1 || true
ok "[health] 已启用开机自检服务"
}

status_check() {
  detect_iface
  echo "=== 优化状态 ($(date '+%F %T')) ==="
  systemctl is-active "net-offload@${IFACE}.service" >/dev/null 2>&1 && ok "Offload: active" || warn "Offload: inactive"
  systemctl is-active "net-irqpin@${IFACE}.service"  >/dev/null 2>&1 && ok "IRQpin: active"  || warn "IRQpin: inactive"
  [[ -f "$SYSCTL_FILE" ]] && ok "Sysctl: 已持久化" || warn "Sysctl: 缺失"
  echo; sysctl -n net.core.rmem_default net.ipv4.udp_mem | nl -ba; echo
}

repair_missing() {
  detect_iface
  [[ -f "$SYSCTL_FILE" ]] || apply_sysctl
  [[ -f "$OFFLOAD_UNIT" ]] || apply_offload
  [[ -f "$IRQPIN_UNIT" ]] || apply_irqpin
  [[ -f "$HEALTH_UNIT" ]] || apply_health_check
  ok "✅ 缺失项已自动修复"
}

case "$ACTION" in
  apply)
    detect_iface
    apply_sysctl
    apply_offload
    apply_irqpin
    apply_health_check
    status_check
    ;;
  status)
    status_check
    ;;
  repair)
    repair_missing
    ;;
  *)
    echo "用法：bash universal_optimize.sh [apply|status|repair]"
    ;;
esac
