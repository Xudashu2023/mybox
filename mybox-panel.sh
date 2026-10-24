#!/usr/bin/env bash
# =============================================================================
# mybox 面板 —— 在服务器上输入 mybox 调出（安装到 /usr/local/bin/mybox）
#
# 这是 mybox-install.sh 的交互外壳，只调用它的子命令，不另写配置逻辑：
#   装/改/卸都走 mybox-install.sh，配置与凭据始终只有一份真相。
#
# 面板自己的设置存 /etc/mybox/panel.conf（SERVER_IP 与端口覆盖），
# 调用 install / show-links 时以环境变量传入，mybox-install.sh 原生支持。
# =============================================================================
set -uo pipefail

DIR="/etc/mybox"
CONF="$DIR/config.json"
PANEL_CONF="$DIR/panel.conf"
SCRIPT="/root/mybox-install.sh"
SERVICE="mybox"

# ---------- 基础 ----------
[ "$(id -u)" -eq 0 ] || { echo "需要 root 运行：请用 root 登录或 sudo mybox"; exit 1; }
[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT（mybox 安装脚本），面板无法工作"; exit 1; }

# 默认值与 mybox-install.sh 保持一致；panel.conf 可覆盖
SERVER_IP=""
PORT_VLESS=40136; PORT_VMESS=2082; PORT_ANYTLS=20917; PORT_HY2=41413; PORT_TUIC=59899
[ -f "$PANEL_CONF" ] && . "$PANEL_CONF"

save_panel_conf() {
  umask 077
  {
    printf "SERVER_IP='%s'\n"    "$SERVER_IP"
    printf "PORT_VLESS='%s'\n"   "$PORT_VLESS"
    printf "PORT_VMESS='%s'\n"   "$PORT_VMESS"
    printf "PORT_ANYTLS='%s'\n"  "$PORT_ANYTLS"
    printf "PORT_HY2='%s'\n"     "$PORT_HY2"
    printf "PORT_TUIC='%s'\n"    "$PORT_TUIC"
  } > "$PANEL_CONF"
}

# 以当前面板设置调用安装脚本
run_script() {
  SERVER_IP="$SERVER_IP" \
  PORT_VLESS="$PORT_VLESS" PORT_VMESS="$PORT_VMESS" PORT_ANYTLS="$PORT_ANYTLS" \
  PORT_HY2="$PORT_HY2" PORT_TUIC="$PORT_TUIC" \
  bash "$SCRIPT" "$@"
}

detect_ip() {
  if [ -n "$SERVER_IP" ]; then echo "$SERVER_IP"; return 0; fi
  # 出口走 WARP 的机器自动探测会拿到 WARP 的 IP，这里只作兜底并给出提示
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "(未设置 SERVER_IP)"
}

pause() { printf "\n按回车返回菜单…"; read -r _ || true; }
confirm() { # confirm "提示" → yes 返回 0
  local ans
  printf "%s [y/N] " "$1"
  read -r ans || return 1
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# ---------- 功能 ----------
show_links() {
  if [ -z "$SERVER_IP" ]; then
    echo "⚠ 未设置 SERVER_IP，下面链接里的 IP 可能不准（出口走代理的机器尤其注意）。"
    echo "  可在菜单 7 里先填服务器公网 IP。"
  fi
  run_script show-links
}

show_clash() {
  if [ -f "$DIR/client/clash.yaml" ]; then
    cat "$DIR/client/clash.yaml"
  else
    echo "还没有生成 Clash 配置，先跑一次菜单 1 或重装。"
  fi
}

show_status() {
  echo "== 服务 =="
  systemctl is-active "$SERVICE" 2>/dev/null || true
  systemctl --no-pager status "$SERVICE" 2>/dev/null | head -n 8 || echo "(服务不存在，可能未安装)"
  echo
  echo "== 端口监听 =="
  ss -tulnp 2>/dev/null | grep -E ":($PORT_VLESS|$PORT_VMESS|$PORT_ANYTLS|$PORT_HY2|$PORT_TUIC)\\b" || echo "(五个端口均未监听)"
  echo
  echo "== 当前设置 =="
  echo "SERVER_IP : $(detect_ip)"
  echo "端口      : VLESS $PORT_VLESS/tcp  VMess $PORT_VMESS/tcp  AnyTLS $PORT_ANYTLS/tcp  Hy2 $PORT_HY2/udp  TUIC $PORT_TUIC/udp"
  if [ -f "$CONF" ] && grep -A6 '"hysteria2"' "$CONF" | grep -q '"h3"'; then
    echo "Hy2 alpn  : h3 ✔（已包含握手修复）"
  else
    echo "Hy2 alpn  : 未检出 h3 —— 建议跑一次菜单 8（更新/重装）应用修复"
  fi
}

restart_service() {
  systemctl restart "$SERVICE" && echo "已重启，状态：$(systemctl is-active "$SERVICE")"
}

show_log() {
  journalctl -u "$SERVICE" --no-pager -n 50 2>/dev/null || echo "(无日志)"
}

test_egress() {
  echo "服务器直连出口 IP："
  curl -s --max-time 10 https://api.ipify.org || echo "(请求失败)"
  echo
  if ss -tulnp 2>/dev/null | grep -q ':40000'; then
    echo "经本机 WARP SOCKS(127.0.0.1:40000) 的出口 IP："
    curl -s --max-time 10 -x socks5h://127.0.0.1:40000 https://api.ipify.org || echo "(请求失败)"
    echo
  fi
}

edit_settings() {
  echo "直接回车 = 保持不变。改完会保存并重跑 install 生效（凭据不变、链接会按新设置重新生成）。"
  local v
  printf "服务器公网 IP [%s]: " "$(detect_ip)";        read -r v || return 0; [ -n "$v" ] && SERVER_IP="$v"
  printf "VLESS 端口 [%s]: "  "$PORT_VLESS";  read -r v || return 0; [ -n "$v" ] && PORT_VLESS="$v"
  printf "VMess 端口 [%s]: "  "$PORT_VMESS";  read -r v || return 0; [ -n "$v" ] && PORT_VMESS="$v"
  printf "AnyTLS 端口 [%s]: " "$PORT_ANYTLS"; read -r v || return 0; [ -n "$v" ] && PORT_ANYTLS="$v"
  printf "Hy2 端口 [%s]: "    "$PORT_HY2";    read -r v || return 0; [ -n "$v" ] && PORT_HY2="$v"
  printf "TUIC 端口 [%s]: "   "$PORT_TUIC";   read -r v || return 0; [ -n "$v" ] && PORT_TUIC="$v"
  save_panel_conf
  echo "已保存到 $PANEL_CONF"
  if confirm "现在重跑 install 让新设置生效？"; then
    run_script install
  else
    echo "已保存，下次重装时生效。"
  fi
}

reinstall() {
  echo "将重跑 mybox-install.sh install：复用现有凭据，只更新内核配置与客户端文件。"
  confirm "继续？" || { echo "已取消"; return 0; }
  run_script install
}

uninstall_box() {
  echo "⚠ 卸载会删除 mybox 服务、/etc/mybox 配置与凭据，五条节点链接随即作废（不可恢复）。"
  confirm "确定卸载？" || { echo "已取消"; return 0; }
  confirm "再确认一次：真的卸载？" || { echo "已取消"; return 0; }
  run_script uninstall
  echo "面板命令 /usr/local/bin/mybox 保留，如需删除：rm /usr/local/bin/mybox"
}

# ---------- 菜单 ----------
while true; do
  cat <<EOF

================ mybox 面板 ================
 服务器 IP : $(detect_ip)
 服务状态  : $(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)
--------------------------------------------
 1) 查看节点链接
 2) 查看 Clash 配置
 3) 服务状态 / 端口 / 当前设置
 4) 重启服务
 5) 查看日志（最近 50 行）
 6) 出口 IP 测试
 7) 修改设置（服务器 IP / 端口）
 8) 更新 / 重装 mybox（应用最新修复）
 9) 卸载 mybox
 0) 退出
============================================
EOF
  printf "请选择 [0-9]: "
  read -r choice || exit 0
  case "$choice" in
    1) show_links;     pause ;;
    2) show_clash;     pause ;;
    3) show_status;    pause ;;
    4) restart_service; pause ;;
    5) show_log;       pause ;;
    6) test_egress;    pause ;;
    7) edit_settings;  pause ;;
    8) reinstall;      pause ;;
    9) uninstall_box;  pause ;;
    0) exit 0 ;;
    *) echo "无效选择";;
  esac
done
