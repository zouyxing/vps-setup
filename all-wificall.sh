#!/bin/bash

# 设置：遇到错误立即退出，提高脚本健壮性
set -e

# =========================================
# 函数：检测系统类型和包管理器
# -----------------------------------------
detect_distro() {
    if command -v apt &> /dev/null; then
        echo "apt"
    elif command -v apk &> /dev/null; then
        echo "apk"
    else
        echo "unknown"
    fi
}

# 函数：检测主网络接口
# -----------------------------------------
get_main_interface() {
    # 获取默认路由使用的接口
    # 依赖：iproute2 包
    ip route | grep default | awk '{print $5}' | head -n1
}

# =========================================
# 全局变量
# =========================================
PACKAGE_MANAGER=$(detect_distro)
MAIN_INTERFACE=$(get_main_interface)
RANDOM_PORT=$((30000 + RANDOM % 35001))

if [ "$PACKAGE_MANAGER" = "unknown" ]; then
    echo "❌ 错误：无法识别当前系统，仅支持 Debian/Ubuntu (apt) 和 Alpine (apk)。"
    exit 1
fi

if [ -z "$MAIN_INTERFACE" ]; then
    echo "❌ 错误：无法检测到主网络接口"
    exit 1
fi

echo "========================================="
echo "开始执行 VPS 自动配置脚本"
echo "========================================="
echo ""
echo "📦 检测到包管理器: ${PACKAGE_MANAGER}"
echo "🔐 已生成随机端口: ${RANDOM_PORT}"
echo "🌐 检测到主网络接口: ${MAIN_INTERFACE}"
echo ""

# 确保以 root 权限执行
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ 警告：脚本未以 root 权限运行。请使用 'sudo -i' 切换到 root 后再执行。"
    exit 1
fi

echo ""
echo "[1/6] 更新系统并安装基础软件包..."
if [ "$PACKAGE_MANAGER" = "apt" ]; then
    # Debian/Ubuntu
    apt-get update
    apt-get install -y iptables sudo ufw expect curl wget iproute2
    # 确保 systemctl 服务可用 (如果缺失)
    apt-get install -y systemd || true
elif [ "$PACKAGE_MANAGER" = "apk" ]; then
    # Alpine Linux
    apk update
    # Alpine 包名差异: iptables, ufw, expect, iproute2 是必要的
    apk add iptables ufw expect curl wget iproute2 openrc # 确保 OpenRC 服务命令可用
fi

echo "✓ 基础软件包安装完成"

echo ""
echo "[2/6] 配置 UFW 防火墙规则 (兼容 Xray 和 Wi-Fi Calling)..."
# --- 强制清空所有现有 UFW 规则 ---
echo "⚠️ 正在强制删除所有现有 UFW 规则..."
ufw --force reset
echo "✓ UFW 规则已清空"
# ----------------------------------------

# 开放 SSH 端口 (推荐)
ufw allow 22/tcp 

# 开放 Wi-Fi Calling/VoIP 必需的 UDP 端口 (IKEv2, NAT Traversal, SIP, RTP/RTCP)
ufw allow 500/udp
ufw allow 4500/udp
ufw allow 5060:5061/udp
# 媒体流 (RTP/RTCP)
ufw allow 10000:60000/udp 

# 开放 Xray/Sing-Box 端口
ufw allow ${RANDOM_PORT}/udp
ufw allow ${RANDOM_PORT}/tcp

echo "y" | ufw enable
echo "✓ 防火墙已启用（端口 ${RANDOM_PORT} 和 VoWiFi 端口已开放）"

echo ""
echo "[3/6] 检查并配置 IP 转发..."
FORWARD_STATUS=$(sysctl -n net.ipv4.ip_forward)
if [ "$FORWARD_STATUS" -eq 0 ]; then
    echo "IP 转发未启用，正在启用..."
    sysctl -w net.ipv4.ip_forward=1

    # 直接使用 tee 写入，无需 grep/sed 复杂判断
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" | tee -a /etc/sysctl.conf
    else
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    fi

    sysctl -p
    echo "✓ IP 转发已启用并保存"
else
    echo "✓ IP 转发已经启用，跳过配置"
fi

echo ""
echo "[4/6] 配置 iptables NAT 规则..."

# --- 清空 iptables NAT 表中的所有规则 ---
echo "⚠️ 正在清空 iptables NAT 表中的所有规则..."
iptables -t nat -F
echo "✓ iptables NAT 表规则已清空"
# ----------------------------------------

# 1. MASQUERADE 规则 (SNAT，用于出站流量伪装)
if ! iptables -t nat -C POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
    echo "✓ 已添加 MASQUERADE 规则 (接口: ${MAIN_INTERFACE})"
else
    echo "✓ MASQUERADE 规则已存在"
fi

# 2. DNAT 规则 (仅针对 Xray/Sing-Box 的 ${RANDOM_PORT}，实现 IP 转发模式)
if ! iptables -t nat -C PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1 2>/dev/null; then
    iptables -t nat -A PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1
    echo "✓ 已添加 Xray/Sing-Box 端口的精确 DNAT 规则 (端口: ${RANDOM_PORT})"
else
    echo "✓ Xray/Sing-Box 端口的精确 DNAT 规则已存在"
fi


echo ""
echo "保存 iptables 规则..."

mkdir -p /etc/iptables
iptables-save | tee /etc/iptables/rules.v4 > /dev/null

# 仅在支持 systemd 的系统上创建和启用 systemd 服务
if command -v systemctl &> /dev/null; then
    if [ ! -f /etc/systemd/system/iptables-restore.service ]; then
        cat << 'EOF' | tee /etc/systemd/system/iptables-restore.service > /dev/null
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable iptables-restore.service
        echo "✓ 已创建 iptables 自动恢复服务 (SystemD)"
    fi
else
    # 针对非 SystemD 系统 (如 Alpine with OpenRC)，提示用户手动配置
    echo "⚠️ 非 SystemD 系统：请确保您的 init 系统已配置 iptables 规则的开机自动加载。"
fi

echo "✓ iptables 规则已永久保存"

echo ""
echo "[5/6] 优化网络算法和拥塞控制算法..."
# 注意：cnm.sh 脚本的可靠性取决于其内容
if bash <(curl -fsSL cnm.sh) 2>/dev/null; then
    echo "✓ 网络优化配置完成"
else
    echo "⚠️  网络优化脚本执行失败，跳过此步骤（不影响主要功能）"
fi

echo ""
echo "[6/6] 下载并自动安装配置代理软件..."

# =================================================================
# Debian/Ubuntu (apt) 使用 Xray 脚本
# =================================================================
if [ "$PACKAGE_MANAGER" = "apt" ]; then
    
    echo "⚙️  检测到 Debian/Ubuntu，准备安装 Xray..."
    
    # 检查并卸载旧配置
    if command -v systemctl &> /dev/null && systemctl is-active --quiet xray 2>/dev/null || [ -f "/usr/local/bin/xray" ]; then
        echo "检测到已安装的 Xray，正在卸载..."
        
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        
        # 彻底清理旧脚本痕迹
        rm -rf /usr/local/xray-script 2>/dev/null || true
        rm
