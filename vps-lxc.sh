#!/bin/bash

# 设置：遇到错误立即退出，提高脚本健壮性
set -e

# =========================================
# 配置变量
# -----------------------------------------
get_main_interface() {
    ip route | grep default | awk '{print $5}' | head -n1
}

MAIN_INTERFACE=$(get_main_interface)

if [ -z "$MAIN_INTERFACE" ]; then
    echo "❌ 错误：无法检测到主网络接口"
    exit 1
fi

# 生成随机端口（40000-65000）用于 Xray
RANDOM_PORT=$((40000 + RANDOM % 35001))

echo "========================================="
echo "开始执行 VPS 自动配置脚本 (默认 SSH)"
echo "========================================="
echo ""
echo "🔐 Xray 随机端口: ${RANDOM_PORT}"
echo "🔒 SSH 端口: 保持系统默认 (22)"
echo "🌐 检测到主网络接口: ${MAIN_INTERFACE}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ 警告：脚本未以 root 权限运行。请使用 'sudo -i' 切换到 root 后再执行。"
    exit 1
fi

echo ""
echo "[1/6] 更新系统并安装基础软件包..."
# =========================================
# 锁文件修复逻辑
# -----------------------------------------
APT_LOCK="/var/lib/dpkg/lock-frontend"
if [ -f "$APT_LOCK" ]; then
    echo "⚠️ 检测到 APT 锁文件，尝试清理锁并修复数据库..."
    killall -9 apt-get || true
    killall -9 dpkg || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
    dpkg --configure -a || true
    echo "✓ 锁文件清理和数据库修复完成。"
fi
# =========================================

apt-get update
apt-get install -y iptables sudo ufw expect curl wget iproute2 net-tools unzip jq uuid-runtime

echo ""
echo "[2/6] 配置 UFW 防火墙规则 (兼容 Xray, VoWiFi)..."
if ufw status >/dev/null 2>&1; then
    ufw allow 22/tcp comment 'Default SSH Port' || true
    ufw allow 500/udp || true
    ufw allow 4500/udp || true
    ufw allow 5060:5061/udp || true
    ufw allow 10000:60000/udp || true
    ufw allow ${RANDOM_PORT}/udp || true
    ufw allow ${RANDOM_PORT}/tcp || true
    echo "y" | ufw enable || true
    echo "✓ 防火墙已启用（SSH: 22，Xray: ${RANDOM_PORT}，VoIP 端口已开放）"
else
    echo "⚠️ 当前环境（如 LXD 容器）不支持 UFW，已自动跳过防火墙配置"
fi

echo ""
echo "[3/6] 检查并配置 IP 转发..."
FORWARD_STATUS=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "1")
if [ "$FORWARD_STATUS" -eq 0 ]; then
    echo "IP 转发未启用，正在尝试启用..."
    if sysctl -w net.ipv4.ip_forward=1 2>/dev/null; then
        if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward = 1" | tee -a /etc/sysctl.conf
        else
            sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
        fi
        sysctl -p || true
        echo "✓ IP 转发已启用并保存"
    else
        echo "⚠️ 当前容器无权限修改 sysctl 内核参数，跳过此步"
    fi
else
    echo "✓ IP 转发已经启用，跳过配置"
fi

echo ""
echo "[4/6] 配置 iptables NAT 规则..."
if iptables -t nat -L >/dev/null 2>&1; then
    if ! iptables -t nat -C POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
        echo "✓ 已添加 MASQUERADE 规则 (接口: ${MAIN_INTERFACE})"
    else
        echo "✓ MASQUERADE 规则已存在"
    fi

    if ! iptables -t nat -C PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1 2>/dev/null; then
        iptables -t nat -A PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1
        echo "✓ 已添加 Xray 端口的精确 DNAT 规则 (端口: ${RANDOM_PORT})"
    else
        echo "✓ Xray 端口的精确 DNAT 规则已存在"
    fi

    mkdir -p /etc/iptables
    iptables-save | tee /etc/iptables/rules.v4 > /dev/null

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
        echo "✓ 已创建 iptables 自动恢复服务"
    fi
    echo "✓ iptables 规则已永久保存"
else
    echo "⚠️ 当前容器无权限操作 iptables NAT 表，已跳过此步"
fi

echo ""
echo "[5/6] 优化网络算法和拥塞控制算法..."
if bash <(curl -fsSL cnm.sh) 2>/dev/null; then
    echo "✓ 网络优化配置完成"
else
    echo "⚠️ 网络优化脚本执行失败，跳过此步骤（不影响主要功能）"
fi

echo ""
echo "[6/6] 清理旧环境、下载 Xray 核心并自动安装配置..."

# 1. 停止服务并彻底删除旧目录 (/usr/local/etc/xray 等)
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

rm -rf /usr/local/etc/xray
rm -rf /usr/local/xray-script
rm -rf /root/.xray-script
rm -rf /usr/local/bin/xray
rm -rf /usr/local/share/xray
rm -rf /etc/systemd/system/xray.service
rm -rf /etc/systemd/system/xray@.service
systemctl daemon-reload 2>/dev/null || true
echo "✓ 旧环境与 /usr/local/etc/xray 已清理"

# 2. 下载最新版 Xray 核心并解压部署
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        XRAY_ZIP="Xray-linux-64.zip"
        ;;
    aarch64|arm64)
        XRAY_ZIP="Xray-linux-arm64-v8a.zip"
        ;;
    *)
        echo "❌ 不支持的系统架构: $ARCH"
        exit 1
        ;;
esac

XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
echo "正在下载最新版 Xray 核心: ${XRAY_URL}"

curl -fL --retry 3 -o "/tmp/${XRAY_ZIP}" "${XRAY_URL}"
mkdir -p /usr/local/share/xray /tmp/xray_extract
unzip -o "/tmp/${XRAY_ZIP}" -d /tmp/xray_extract

mv /tmp/xray_extract/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
mv /tmp/xray_extract/*.dat /usr/local/share/xray/
rm -rf /tmp/xray_extract "/tmp/${XRAY_ZIP}"
echo "✓ Xray 核心安装完成: $(/usr/local/bin/xray version | head -n1)"

# 3. 预创建配置目录与 systemd 服务文件 (防止 handler.sh 写入报错)
mkdir -p /usr/local/etc/xray /var/log/xray

cat << 'EOF' > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
echo "✓ 配置目录 /usr/local/etc/xray 与 systemd 服务已就绪"

# 4. 下载并运行自动化配置脚本
echo "等待 2 秒后开始运行配置脚本..."
sleep 2

wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/zouyxing/Xray-script/refs/heads/main/install.sh
chmod +x ${HOME}/Xray-script.sh

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
echo "生成的 Xray 随机端口为: ${RANDOM_PORT}"
echo "（若为 LXD NAT VPS，请记得在商家面板将外部端口映射到内网的 ${RANDOM_PORT}）"
echo ""
echo "请使用以下命令检查状态："
echo "  systemctl status xray             # 查看 Xray 运行状态"
echo "  ss -tulnp | grep ${RANDOM_PORT}   # 查看端口监听状态"
echo ""
