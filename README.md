注意:仅限开荒的vps

有程序服务的需要重新开放端口






全自动安装Xray以及一些设置脚本:

1.生成随机端口（30000-65000）用于 Xray.

2.强制清理锁并修复数据库.

3.开放 Wi-Fi Calling/VoIP 必需的 UDP 端口.

4.优化网络算法和拥塞控制算法.

5.下载并自动安装配置 Xray

debian+Ubuntu

```bash
curl -fsSL https://raw.githubusercontent.com/zouyxing/vps-setup/refs/heads/main/vps-one.sh | tr -d '\r' | bash
```

只有IPV6的vps

```bash
curl -fsSL https://raw.githubusercontent.com/zouyxing/vps-setup/refs/heads/main/vps-ip6.sh | tr -d '\r' | bash
```

需要开放443,80,25端口自建mail的vps

```bash
curl -fsSL https://raw.githubusercontent.com/zouyxing/vps-setup/refs/heads/main/vps-mail.sh | tr -d '\r' | bash
```

lxc容器

```bash
curl -fsSL https://raw.githubusercontent.com/zouyxing/vps-setup/refs/heads/main/lxc-wificall.sh | tr -d '\r' | bash
```

Alpine系统

```bash
curl -fsSL https://raw.githubusercontent.com/zouyxing/vps-setup/refs/heads/main/lxc-wificall.sh | tr -d '\r' | bash
```

