#!/bin/bash

set -e

echo "========================================="
echo "开始执行 VPS 自动配置脚本"
echo "========================================="

echo ""
echo "[1/6] 更新系统并安装基础软件包..."
sudo apt-get update
sudo apt-get install -y iptables sudo ufw expect

echo ""
echo "[2/6] 配置 UFW 防火墙规则..."
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw allow 50000:60000/tcp
sudo ufw allow 10000:60000/tcp
sudo ufw allow 10000:60000/udp
sudo ufw allow 50000:60000/udp
sudo ufw allow 4500/udp
sudo ufw allow 500/udp
sudo ufw allow 5060:5061/udp
sudo ufw allow 38626/udp
sudo ufw allow 38626/tcp

echo "y" | sudo ufw enable
echo "防火墙已启用"

echo ""
echo "[3/6] 检查并配置 IP 转发..."
FORWARD_STATUS=$(sysctl -n net.ipv4.ip_forward)
if [ "$FORWARD_STATUS" -eq 0 ]; then
    echo "IP 转发未启用，正在启用..."
    sudo sysctl -w net.ipv4.ip_forward=1

    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
    else
        sudo sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    fi

    sudo sysctl -p
    echo "IP 转发已启用并保存"
else
    echo "IP 转发已经启用，跳过配置"
fi

echo ""
echo "[4/6] 配置 iptables NAT 规则..."

if ! sudo iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    echo "已添加 MASQUERADE 规则"
else
    echo "MASQUERADE 规则已存在"
fi

if ! sudo iptables -t nat -C PREROUTING -p udp --dport 10000:60000 -j DNAT --to-destination 127.0.0.1 2>/dev/null; then
    sudo iptables -t nat -A PREROUTING -p udp --dport 10000:60000 -j DNAT --to-destination 127.0.0.1
    echo "已添加 DNAT 规则"
else
    echo "DNAT 规则已存在"
fi

echo ""
echo "保存 iptables 规则..."

sudo mkdir -p /etc/iptables
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null

if [ ! -f /etc/systemd/system/iptables-restore.service ]; then
    cat << 'EOF' | sudo tee /etc/systemd/system/iptables-restore.service > /dev/null
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

    sudo systemctl daemon-reload
    sudo systemctl enable iptables-restore.service
    echo "已创建 iptables 自动恢复服务"
fi

echo "iptables 规则已永久保存"

echo ""
echo "[5/6] 优化算法和拥塞控制算法..."
bash <(curl -fsSL cnm.sh)
echo "优化算法和拥塞控制算法配置完成"

echo ""
echo "[6/6] 下载并自动安装配置 Xray..."
wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/zxcvos/Xray-script/refs/heads/main/install.sh

expect << 'EOF'
set timeout 300
spawn bash /root/Xray-script.sh

# ------------------------------
# ⭐ 自动检测是否有更新
# ------------------------------
expect {
    -re {是否更新.*} {
        puts "检测到可更新 → 自动发送 Y"
        send "Y\r"
        exp_continue
    }
    timeout {
        puts "未检测到更新提示 → 继续安装"
    }
}

# ------------------------------
# ② 主菜单：完整安装 → 输入 1
# ------------------------------
expect {
    -re {请选择操作} {
        puts "主菜单出现 → 选择 1 (完整安装)"
        send "1\r"
    }
    "*请选择*" {
        puts "模糊匹配主菜单 → 选择 1"
        send "1\r"
    }
    timeout {
        puts "主菜单匹配失败"; exit 1
    }
}

# ------------------------------
# ③ 安装流程：自定义配置 → 输入 2
# ------------------------------
expect {
    -re {请选择操作} {
        puts "安装流程菜单 → 选择 2 (自定义配置)"
        send "2\r"
    }
    "*请选择*" { send "2\r" }
    timeout { puts "安装流程匹配失败"; exit 1 }
}

# ------------------------------
# ④ 装载管理：稳定版 → 输入 2
# ------------------------------
expect {
    -re {请选择操作} {
        puts "装载管理菜单 → 选择 2 (稳定版)"
        send "2\r"
    }
    "*请选择*" { send "2\r" }
    timeout { puts "装载管理匹配失败"; exit 1 }
}

# ------------------------------
# ⑤ 可选配置：VLESS+Vision+REALITY → 输入 2
# ------------------------------
expect {
    -re {请选择操作} {
        puts "可选配置菜单 → 选择 2 (VLESS+Vision+REALITY)"
        send "2\r"
    }
    "*请选择*" { send "2\r" }
    timeout { puts "可选配置匹配失败"; exit 1 }
}

# ------------------------------
# ⑥ 是否重置路由规则 → 输入 n
# ------------------------------
expect {
    -re {是否重置路由规则} {
        puts "不重置路由规则 → 输入 n"
        send "n\r"
    }
    timeout { puts "等待路由规则重置提示失败"; exit 1 }
}

# ------------------------------
# ⑦ 端口 → 输入 38626
# ------------------------------
expect {
    -re {请输入 port} {
        puts "设置端口为 38626"
        send "38626\r"
    }
    timeout { puts "端口输入失败"; exit 1 }
}

# ------------------------------
# ⑧ UUID → 默认自动生成
# ------------------------------
expect {
    -re {请输入 UUID} {
        puts "UUID 自动生成"
        send "\r"
    }
    timeout { puts "UUID 输入失败"; exit 1 }
}

# ------------------------------
# ⑨ target → 默认
# ------------------------------
expect {
    -re {请输入目标域名} {
        puts "目标域名自动选择"
        send "\r"
    }
    timeout { puts "目标域名输入失败"; exit 1 }
}

# ------------------------------
# ⑩ shortId → 默认
# ------------------------------
expect {
    -re {请输入 shortId} {
        puts "shortId 自动生成"
        send "\r"
    }
    timeout { puts "shortId 输入失败"; exit 1 }
}

# ------------------------------
# 结束
# ------------------------------
expect {
    eof { puts "Xray 安装配置完成" }
    timeout { puts "安装过程超时"; exit 1 }
}
echo "Xray 自动安装配置完成"

echo ""
echo "========================================="
echo "VPS 配置完成！"
echo "========================================="
echo ""
echo "已完成的配置："
echo "✓ 系统更新和基础软件安装"
echo "✓ UFW 防火墙规则配置"
echo "✓ IP 转发启用"
echo "✓ iptables NAT 规则配置"
echo "✓ 优化算法和拥塞控制算法"
echo "✓ Xray 自动安装配置"
echo ""
echo "请使用以下命令检查状态："
echo "  sudo ufw status          # 查看防火墙状态"
echo "  sudo iptables -t nat -L  # 查看 NAT 规则"
echo "  sysctl net.ipv4.ip_forward  # 查看转发状态"
echo ""
