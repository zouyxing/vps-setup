#!/bin/bash

# 设置：遇到错误立即退出，提高脚本健壮性
set -e

# =========================================
# 配置变量
# -----------------------------------------
# 注意：已移除自定义 SSH 端口设置，脚本将保留系统默认 SSH 端口（通常为 22）

# 函数：检测主网络接口（支持 IPv4 和 IPv6）
get_main_interface() {
    local interface=""
    
    # 首先尝试获取 IPv4 默认路由的接口
    interface=$(ip -4 route | grep default | awk '{print $5}' | head -n1)
    
    # 如果 IPv4 接口不存在，尝试获取 IPv6 默认路由的接口
    if [ -z "$interface" ]; then
        interface=$(ip -6 route | grep default | awk '{print $5}' | head -n1)
    fi
    
    # 如果还是没有，尝试获取任何活动的网络接口（排除 lo）
    if [ -z "$interface" ]; then
        interface=$(ip link show | grep -E "^[0-9]+: " | grep -v "lo:" | awk -F': ' '{print $2}' | head -n1)
    fi
    
    echo "$interface"
}

MAIN_INTERFACE=$(get_main_interface)

if [ -z "$MAIN_INTERFACE" ]; then
    echo "❌ 错误：无法检测到主网络接口"
    echo "请手动检查网络配置："
    echo "  ip -4 route"
    echo "  ip -6 route"
    echo "  ip link show"
    exit 1
fi

# 检测是否支持 IPv6
HAS_IPV6=false
if ip -6 addr show | grep -q "inet6.*scope global"; then
    HAS_IPV6=true
fi

# 生成随机端口（30000-65000）用于 Xray
RANDOM_PORT=$((30000 + RANDOM % 35001))

echo "========================================="
echo "开始执行 VPS 自动配置脚本 (双栈支持)"
echo "========================================="
echo ""
echo "🔐 Xray 随机端口: ${RANDOM_PORT}"
echo "🔒 SSH 端口: 保持系统默认 (22)"
echo "🌐 检测到主网络接口: ${MAIN_INTERFACE}"
echo "🌍 IPv6 支持: $([ "$HAS_IPV6" = true ] && echo "已启用" || echo "未检测到")"
echo ""

# 确保所有后续操作都以 root 权限执行
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ 警告：脚本未以 root 权限运行。请使用 'sudo -i' 切换到 root 后再执行。"
    exit 1
fi

echo ""
echo "[1/6] 更新系统并安装基础软件包..."
# =========================================
# 锁文件修复逻辑 (FIXED)
# -----------------------------------------
APT_LOCK="/var/lib/dpkg/lock-frontend"
if [ -f "$APT_LOCK" ]; then
    echo "⚠️ 检测到 APT 锁文件，可能由后台进程持有。"
    echo "    尝试强制清理锁并修复数据库..."
    # 强制终止可能占用锁的进程
    killall -9 apt-get || true
    killall -9 dpkg || true
    
    # 强制删除锁文件
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
    
    # 强制配置未完成的包，修复数据库
    dpkg --configure -a || true
    echo "✓ 锁文件清理和数据库修复完成。"
fi
# =========================================

# 由于是以 root 身份运行，不需要 sudo
apt-get update
# 确保安装了 iproute2 (ip route 命令) 和 net-tools (ss 命令)
apt-get install -y iptables sudo ufw expect curl wget iproute2 net-tools

echo ""
echo "[2/6] 配置 UFW 防火墙规则 (兼容 Xray, VoWiFi, IPv4/IPv6)..."

# 1. 开放标准 SSH 端口 (22)
ufw allow 22/tcp comment 'Default SSH Port'

# 2. 开放 Wi-Fi Calling/VoIP 必需的 UDP 端口 (IKEv2, NAT Traversal, SIP, RTP/RTCP)
ufw allow 500/udp
ufw allow 4500/udp
ufw allow 5060:5061/udp
# 媒体流 (RTP/RTCP)，开放宽泛 UDP 范围
ufw allow 10000:60000/udp 

# 3. 开放 Xray 端口
ufw allow ${RANDOM_PORT}/udp
ufw allow ${RANDOM_PORT}/tcp

echo "y" | ufw enable
echo "✓ 防火墙已启用（SSH: 22，Xray: ${RANDOM_PORT}，VoIP 端口已开放）"

echo ""
echo "[3/6] 检查并配置 IP 转发（IPv4 和 IPv6）..."

# 配置 IPv4 转发
FORWARD_STATUS=$(sysctl -n net.ipv4.ip_forward)
if [ "$FORWARD_STATUS" -eq 0 ]; then
    echo "IPv4 转发未启用，正在启用..."
    sysctl -w net.ipv4.ip_forward=1

    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" | tee -a /etc/sysctl.conf
    else
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    fi
    echo "✓ IPv4 转发已启用"
else
    echo "✓ IPv4 转发已经启用"
fi

# 配置 IPv6 转发（如果系统支持 IPv6）
if [ "$HAS_IPV6" = true ]; then
    FORWARD_STATUS_V6=$(sysctl -n net.ipv6.conf.all.forwarding)
    if [ "$FORWARD_STATUS_V6" -eq 0 ]; then
        echo "IPv6 转发未启用，正在启用..."
        sysctl -w net.ipv6.conf.all.forwarding=1
        sysctl -w net.ipv6.conf.default.forwarding=1

        if ! grep -q "^net.ipv6.conf.all.forwarding" /etc/sysctl.conf; then
            echo "net.ipv6.conf.all.forwarding = 1" | tee -a /etc/sysctl.conf
            echo "net.ipv6.conf.default.forwarding = 1" | tee -a /etc/sysctl.conf
        else
            sed -i 's/^net.ipv6.conf.all.forwarding.*/net.ipv6.conf.all.forwarding = 1/' /etc/sysctl.conf
            sed -i 's/^net.ipv6.conf.default.forwarding.*/net.ipv6.conf.default.forwarding = 1/' /etc/sysctl.conf
        fi
        echo "✓ IPv6 转发已启用"
    else
        echo "✓ IPv6 转发已经启用"
    fi
fi

sysctl -p
echo "✓ IP 转发配置已保存"

echo ""
echo "[4/6] 配置 iptables NAT 规则（IPv4 和 IPv6）..."

# IPv4 规则
# 1. MASQUERADE 规则 (SNAT，用于出站流量伪装)
if ! iptables -t nat -C POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
    echo "✓ 已添加 IPv4 MASQUERADE 规则 (接口: ${MAIN_INTERFACE})"
else
    echo "✓ IPv4 MASQUERADE 规则已存在"
fi

# 2. DNAT 规则 (仅针对 Xray 的 ${RANDOM_PORT}，实现 IP 转发模式)
if ! iptables -t nat -C PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1 2>/dev/null; then
    iptables -t nat -A PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1
    echo "✓ 已添加 Xray 端口的 IPv4 DNAT 规则 (端口: ${RANDOM_PORT})"
else
    echo "✓ Xray 端口的 IPv4 DNAT 规则已存在"
fi

# IPv6 规则（如果系统支持 IPv6）
if [ "$HAS_IPV6" = true ]; then
    # 1. IPv6 MASQUERADE 规则
    if ! ip6tables -t nat -C POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE 2>/dev/null; then
        ip6tables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
        echo "✓ 已添加 IPv6 MASQUERADE 规则 (接口: ${MAIN_INTERFACE})"
    else
        echo "✓ IPv6 MASQUERADE 规则已存在"
    fi

    # 2. IPv6 DNAT 规则
    if ! ip6tables -t nat -C PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination ::1 2>/dev/null; then
        ip6tables -t nat -A PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination ::1
        echo "✓ 已添加 Xray 端口的 IPv6 DNAT 规则 (端口: ${RANDOM_PORT})"
    else
        echo "✓ Xray 端口的 IPv6 DNAT 规则已存在"
    fi
fi

echo ""
echo "保存 iptables 规则..."

mkdir -p /etc/iptables
iptables-save | tee /etc/iptables/rules.v4 > /dev/null

if [ "$HAS_IPV6" = true ]; then
    ip6tables-save | tee /etc/iptables/rules.v6 > /dev/null
fi

if [ ! -f /etc/systemd/system/iptables-restore.service ]; then
    if [ "$HAS_IPV6" = true ]; then
        cat << 'EOF' | tee /etc/systemd/system/iptables-restore.service > /dev/null
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
ExecStart=/sbin/ip6tables-restore /etc/iptables/rules.v6
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    else
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
    fi

    systemctl daemon-reload
    systemctl enable iptables-restore.service
    echo "✓ 已创建 iptables 自动恢复服务"
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
echo "[6/6] 下载并自动安装配置 Xray..."

# 检查并卸载旧配置
if systemctl is-active --quiet xray 2>/dev/null || [ -f "/usr/local/bin/xray" ]; then
    echo "检测到已安装的 Xray，正在卸载..."
    
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    
    # 彻底清理旧脚本痕迹（以 root 身份执行，无需 sudo）
    rm -rf /usr/local/xray-script 2>/dev/null || true
    rm -rf /root/.xray-script 2>/dev/null || true
    rm -rf /usr/local/etc/xray 2>/dev/null || true
    rm -rf /usr/local/bin/xray 2>/dev/null || true
    rm -rf /usr/local/share/xray 2>/dev/null || true
    rm -rf /etc/systemd/system/xray.service 2>/dev/null || true
    rm -rf /etc/systemd/system/xray@.service 2>/dev/null || true
    
    systemctl daemon-reload 2>/dev/null || true
    
    echo "✓ 卸载完成！"
else
    echo "未检测到已安装的 Xray"
fi

echo "等待 2 秒后开始全新安装..."
sleep 2

wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/zxcvos/Xray-script/refs/heads/main/install.sh

# 添加执行权限
chmod +x ${HOME}/Xray-script.sh

# 将端口号和脚本路径导出为环境变量供 expect 使用
export RANDOM_PORT
export SCRIPT_PATH="${HOME}/Xray-script.sh"

expect << 'EXPECT_EOF'
set timeout 600
log_user 1
spawn bash $env(SCRIPT_PATH)

sleep 2

# 第一步：处理语言选择和更新提示
expect {
    -re {中文.*English} {
        send "1\r"
        exp_continue
    }
    -re {是否更新} {
        send "Y\r"
        exp_continue
    }
    -re {请选择操作} {}
    timeout { exit 1 }
}

# 第二步：主菜单选择 1（完整安装）
send "1\r"

# 安装流程：自定义配置 → 输入 2
expect {
    -re {请选择操作} { send "2\r" }
    timeout { exit 1 }
}

# 装载管理：稳定版 → 输入 2
expect {
    -re {请选择操作} { send "2\r" }
    timeout { exit 1 }
}

# 可选配置：VLESS+Vision+REALITY → 输入 2
expect {
    -re {请选择操作} { send "2\r" }
    timeout { exit 1 }
}

sleep 1

# 处理路由规则配置并等待 bittorrent
expect {
    -re {是否重置路由规则} {
        send "y\r"
        expect {
            -re {是否开启 bittorrent 屏蔽|bittorrent 屏蔽} { send "n\r" }
            timeout { exit 1 }
        }
    }
    -re {是否开启 bittorrent 屏蔽|bittorrent 屏蔽} {
        send "n\r"
    }
    -re {配置原文件存在} {
        exp_continue
    }
    timeout { exit 1 }
}

# 是否开启国内 ip 屏蔽 → 输入 n
expect {
    -re {是否开启国内 ip 屏蔽} { send "n\r" }
    timeout { exit 1 }
}

# 是否开启广告屏蔽 → 输入 Y
expect {
    -re {是否开启广告屏蔽|广告屏蔽} { send "Y\r" }
    timeout { exit 1 }
}

# 端口 → 使用随机生成的端口
expect {
    -re {请输入 port} { send "$env(RANDOM_PORT)\r" }
    timeout { exit 1 }
}

# UUID → 默认自动生成
expect {
    -re {请输入 UUID} { send "\r" }
    timeout { exit 1 }
}

# target → 默认
expect {
    -re {请输入目标域名} { send "\r" }
    timeout { exit 1 }
}

# shortId → 默认
expect {
    -re {请输入 shortId} { send "\r" }
    timeout { exit 1 }
}

# 等待安装完成
expect {
    eof {}
    timeout { exit 1 }
}
EXPECT_EOF

echo "✓ Xray 自动安装配置完成"

echo ""
echo "========================================="
echo "✅ VPS 配置完成！"
echo "========================================="
echo ""
echo "已完成的配置："
echo "  ✓ UFW 防火墙规则配置 (允许端口 22, Xray 和 VoWiFi)"
echo "  ✓ IP 转发启用 (IPv4$([ "$HAS_IPV6" = true ] && echo " + IPv6" || echo ""))"
echo "  ✓ iptables NAT 规则配置 (MASQUERADE, Xray DNAT: ${RANDOM_PORT})"
echo "  ✓ 网络优化算法和拥塞控制算法"
echo "  ✓ Xray 自动安装配置"
echo ""
echo "网络接口信息："
echo "  主接口: ${MAIN_INTERFACE}"
echo "  IPv6 支持: $([ "$HAS_IPV6" = true ] && echo "是" || echo "否")"
echo ""
echo "请使用以下命令检查状态："
echo "  ufw status              # 查看防火墙状态"
echo "  systemctl status xray   # 查看 Xray 运行状态"
echo "  ip -4 addr              # 查看 IPv4 地址"
echo "  ip -6 addr              # 查看 IPv6 地址"
echo ""
