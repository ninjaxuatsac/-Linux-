# 🧠 Universal Optimize - Linux 通用安全性能优化脚本

适用于 **Debian / Ubuntu / CentOS / KVM / BareMetal / XanMod** 等环境的一键通用优化脚本。兼顾 **性能 / 稳定 / 安全**，让系统在不牺牲可靠性的情况下发挥最大效能。

---

## 🚀 功能概览

✅ **系统内核网络优化（sysctl）**  
- 增强 TCP/UDP 缓冲区  
- 启用高性能 socket 参数  
- 降低内存交换率，减少 IO 延迟  
- 合理提升连接队列与文件句柄上限  

✅ **关闭网卡 Offload（GRO/GSO/TSO/LRO 等）**  
- 减少虚拟化环境中网络延迟  
- 适配 KVM、Xen、Hyper-V 等虚拟网卡  
- 持久化生效（systemd 服务自动加载）

✅ **IRQ 中断绑定**  
- 将网卡中断固定在 CPU0，提高处理效率  
- 兼容虚拟机（无 IRQ 情况下自动跳过）

✅ **系统自检与自动修复机制**  
- 每次开机后 5 秒内自检系统状态  
- 自动修复缺失的优化配置  
- 日志写入 systemd/journalctl 可查

✅ **纯净安全**  
- 不修改防火墙、不修改代理配置  
- 不影响 sing-box / hysteria2 / xray 等程序运行  
- 可重复运行，不破坏系统原有设定  

---

## 🧩 安装与运行

📱 **（手机或服务器上都可执行）**

```bash
# 一键执行优化（推荐）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/buyi06/-Linux-/main/universal_optimize.sh)"

# 查看状态
bash universal_optimize.sh status

# 自动修复缺失项
bash universal_optimize.sh repair
```

💡 建议执行完毕后重启系统，获取最佳网络稳定性与带宽性能。

---

## 🧠 参数说明

| 命令 | 说明 |
|------|------|
| apply | 执行优化并持久化（默认） |
| status | 查看当前系统优化状态 |
| repair | 自动修复缺失的配置项 |

---

## 🔍 自检日志查看

查看自检健康日志：

```bash
journalctl -u sys-guard-health -b --no-pager
```

---

## ⚙️ 文件说明

| 文件 | 功能 |
|------|------|
| /etc/sysctl.d/99-universal-optimize.conf | 网络与系统内核参数优化 |
| /etc/systemd/system/net-offload@.service | 自动关闭网卡 Offload 功能 |
| /etc/systemd/system/net-irqpin@.service | 绑定网卡中断到 CPU0 |
| /etc/systemd/system/sys-guard-health.service | 系统自检与状态监控 |
| /usr/local/sbin/universal-optimize | 主脚本路径（可手动复制） |

---

## 🧰 推荐用法

适用于：
- HY2 / Hysteria2 / Sing-box 等高速代理环境
- 高并发下载 / 多线程传输场景
- 高延迟线路稳定性优化
- VPS / KVM / 物理服务器长期运行优化

---

## 💬 作者 & 协作

Created by buyi06  
🐧 Linux System Tuning / Network Performance Engineering  
💌 欢迎提出 Issue / PR 以改进脚本

---

## ⚠️ 声明

本脚本为安全优化工具，不执行任何危险操作。  
执行者需自行确认环境兼容性。  
脚本对系统配置的修改均可通过手动删除配置文件恢复。
