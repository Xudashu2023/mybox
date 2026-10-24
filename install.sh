#!/usr/bin/env bash
# =============================================================================
# mybox 一键安装：本体 + 面板一次装齐
#
# 用法（root 或 sudo）：
#   curl -fsSL https://raw.githubusercontent.com/Xudashu2023/mybox/main/install.sh | sudo bash
#
# 可选环境变量（透传给本体安装脚本）：
#   SERVER_IP   服务器公网 IP（出站经 WARP/透明代理的机器必须手动指定，
#               否则自动探测到的是代理出口 IP，节点链接会写错）
#   PORT_VLESS / PORT_VMESS / PORT_ANYTLS / PORT_HY2 / PORT_TUIC
#               不指定则首次安装随机生成并持久化
#   REALITY_SNI / CERT_CN / SB_VERSION
# =============================================================================
set -euo pipefail

RAW="https://raw.githubusercontent.com/Xudashu2023/mybox/main"
TS="$(date +%s)"

[ "$(id -u)" -eq 0 ] || { echo "[mybox] 需要 root 运行（请加 sudo）"; exit 1; }

echo "[mybox] 1/3 下载本体安装脚本…"
curl -fsSL "$RAW/mybox-install.sh?t=$TS" -o /root/mybox-install.sh
bash -n /root/mybox-install.sh

echo "[mybox] 2/3 安装本体（sing-box 五协议）…"
bash /root/mybox-install.sh install

echo "[mybox] 3/3 安装面板…"
curl -fsSL "$RAW/mybox-panel.sh?t=$TS" -o /usr/local/bin/mybox
chmod 755 /usr/local/bin/mybox
mkdir -p /etc/mybox
if [ -n "${SERVER_IP:-}" ]; then
  if [ -f /etc/mybox/panel.conf ]; then
    grep -q '^SERVER_IP=' /etc/mybox/panel.conf || printf "SERVER_IP='%s'\n" "$SERVER_IP" >> /etc/mybox/panel.conf
  else
    printf "SERVER_IP='%s'\n" "$SERVER_IP" > /etc/mybox/panel.conf
  fi
fi

echo "[mybox] 全部完成！输入 mybox 打开面板（选 1 看节点链接，选 5 节点测速）"
