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

echo "[my-vpn] 4/4 安装 mv 快捷入口…"
# mv 本身是系统移动命令，不能直接拿面板覆盖它，否则面板自己的更新
#（mv 新脚本 旧脚本）和系统里所有调 mv 的地方都会坏。所以这里只装一个
#包装：无参数时打开 my-vpn 面板，带参数时原样交给 /bin/mv。
if [ -f /usr/local/bin/mv ] && ! grep -q 'my-vpn 快捷入口' /usr/local/bin/mv 2>/dev/null; then
  /bin/mv /usr/local/bin/mv /usr/local/bin/mv.my-vpn-bak
  echo "[my-vpn] /usr/local/bin/mv 已有非本项目文件，已备份到 /usr/local/bin/mv.my-vpn-bak"
fi
cat > /usr/local/bin/mv <<'EOF'
#!/usr/bin/env bash
# my-vpn 快捷入口：无参数时打开 my-vpn 面板；带参数时就是系统 mv。
if [ "$#" -eq 0 ]; then exec /usr/local/bin/my-vpn; else exec /bin/mv "$@"; fi
EOF
chmod 755 /usr/local/bin/mv
echo "[my-vpn] mv 快捷入口已装好：直接输 mv 进面板，mv 文件1 文件2 仍是系统移动"
echo "[my-vpn] 全部完成！输入 mv 打开面板（my-vpn 也一样；选 1 看节点链接，选 5 节点测速）"
