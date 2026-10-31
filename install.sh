#!/usr/bin/env bash
# =============================================================================
# My-vpn 一键安装：本体 + 面板一次装齐
#
# 用法（root 或 sudo）：
#   curl -fsSL https://raw.githubusercontent.com/Xudashu2023/My-vpn/main/install.sh | sudo bash
#
# 可选环境变量（透传给本体安装脚本）：
#   SERVER_IP   服务器公网 IP（出站经 WARP/透明代理的机器必须手动指定，
#               否则自动探测到的是代理出口 IP，节点链接会写错）
#   PORT_VLESS / PORT_VMESS / PORT_ANYTLS / PORT_HY2 / PORT_TUIC
#               不指定则首次安装随机生成并持久化
#   REALITY_SNI / CERT_CN / SB_VERSION
# =============================================================================
set -euo pipefail

RAW="https://raw.githubusercontent.com/Xudashu2023/My-vpn/main"
TS="$(date +%s)"

[ "$(id -u)" -eq 0 ] || { echo "[my-vpn] 需要 root 运行（请加 sudo）"; exit 1; }

echo "[my-vpn] 1/3 下载本体安装脚本…"
curl -fsSL "$RAW/my-vpn-install.sh?t=$TS" -o /root/my-vpn-install.sh
bash -n /root/my-vpn-install.sh

echo "[my-vpn] 2/3 安装本体（sing-box 五协议）…"
bash /root/my-vpn-install.sh install

echo "[my-vpn] 3/3 安装面板…"
curl -fsSL "$RAW/my-vpn-panel.sh?t=$TS" -o /usr/local/bin/my-vpn
chmod 755 /usr/local/bin/my-vpn
mkdir -p /etc/my-vpn
if [ -n "${SERVER_IP:-}" ]; then
  if [ -f /etc/my-vpn/panel.conf ]; then
    grep -q '^SERVER_IP=' /etc/my-vpn/panel.conf || printf "SERVER_IP='%s'\n" "$SERVER_IP" >> /etc/my-vpn/panel.conf
  else
    printf "SERVER_IP='%s'\n" "$SERVER_IP" > /etc/my-vpn/panel.conf
  fi
fi

echo "[my-vpn] 全部完成！输入 my-vpn 打开面板（选 1 看节点链接，选 5 节点测速）"
