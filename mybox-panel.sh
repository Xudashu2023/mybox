#!/usr/bin/env bash
# =============================================================================
# mybox 面板 v2 —— 在服务器上输入 mybox 调出（安装到 /usr/local/bin/mybox）
#
# 彩色仪表盘 + 功能菜单。所有装/改/卸仍走 mybox-install.sh 的子命令，
# 面板只是交互外壳，配置与凭据始终只有一份真相。
#
# 面板自己的设置存 /etc/mybox/panel.conf（SERVER_IP、端口、REALITY_SNI、
# CERT_CN），调用 install / show-links 时以环境变量传入（脚本原生支持）。
# =============================================================================
set -uo pipefail

PANEL_VERSION="2.3"
DIR="/etc/mybox"
CONF="$DIR/config.json"
CREDS="$DIR/credentials.env"
PANEL_CONF="$DIR/panel.conf"
SCRIPT="/root/mybox-install.sh"
PANEL_SELF="/usr/local/bin/mybox"
BIN="/usr/local/bin/sing-box"
SERVICE="mybox"
RAW_BASE="https://raw.githubusercontent.com/Xudashu2023/mybox/main"
BACKUP_DIR="/root/mybox-backups"

# ---------- 颜色（仅终端下启用；NO_COLOR / FORCE_COLOR 可覆盖） ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then COLOR=1; else COLOR=0; fi
[ "${FORCE_COLOR:-}" = "1" ] && COLOR=1
if [ "$COLOR" = "1" ]; then
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'
  MAG=$'\033[35m'; CYN=$'\033[36m'; WHT=$'\033[97m'
  BRED=$'\033[1;31m'; BGRN=$'\033[1;32m'; BYEL=$'\033[1;33m'
  BCYN=$'\033[1;36m'; BMAG=$'\033[1;35m'
else
  R=""; B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; WHT=""
  BRED=""; BGRN=""; BYEL=""; BCYN=""; BMAG=""
fi

ok()   { printf "%s✓%s %s\n" "$BGRN" "$R" "$*"; }
warn() { printf "%s⚠%s %s\n" "$BYEL" "$R" "$*"; }
err()  { printf "%s✗%s %s\n" "$BRED" "$R" "$*"; }
dot()  { # dot 0/1 → 彩色圆点
  if [ "$1" = "1" ]; then printf "%s●%s" "$GRN" "$R"; else printf "%s●%s" "$RED" "$R"; fi
}
bar() { # bar 百分比 → 20 格进度条
  local pct="$1" width=20 filled i out=""
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( pct * width / 100 ))
  local col="$GRN"; [ "$pct" -ge 70 ] && col="$YEL"; [ "$pct" -ge 90 ] && col="$RED"
  for ((i=0;i<filled;i++)); do out="${out}█"; done
  for ((i=filled;i<width;i++)); do out="${out}░"; done
  printf "%s%s%s %s%%" "$col" "$out" "$R" "$pct"
}
pause() { printf "\n%s按回车返回…%s" "$D" "$R"; read -r _ || true; }
confirm() {
  local ans
  printf "%s%s [y/N]%s " "$BYEL" "$1" "$R"
  read -r ans || return 1
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}
hr() { printf "%s────────────────────────────────────────────────────────────%s\n" "$D" "$R"; }

# ---------- 基础 ----------
[ "$(id -u)" -eq 0 ] || { err "需要 root 运行：请用 root 登录或 sudo mybox"; exit 1; }
[ -f "$SCRIPT" ] || { err "找不到 $SCRIPT（mybox 安装脚本），面板无法工作"; exit 1; }

# 默认值与 mybox-install.sh 保持一致；panel.conf 可覆盖
SERVER_IP=""
PORT_VLESS=40136; PORT_VMESS=2082; PORT_ANYTLS=20917; PORT_HY2=41413; PORT_TUIC=59899
REALITY_SNI="apple.com"; CERT_CN="www.bing.com"
SB_VERSION="1.14.3"
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
    printf "REALITY_SNI='%s'\n"  "$REALITY_SNI"
    printf "CERT_CN='%s'\n"      "$CERT_CN"
    printf "SB_VERSION='%s'\n"   "$SB_VERSION"
  } > "$PANEL_CONF"
}

run_script() { # 以当前面板设置调用安装脚本
  SERVER_IP="$SERVER_IP" SB_VERSION="$SB_VERSION" \
  PORT_VLESS="$PORT_VLESS" PORT_VMESS="$PORT_VMESS" PORT_ANYTLS="$PORT_ANYTLS" \
  PORT_HY2="$PORT_HY2" PORT_TUIC="$PORT_TUIC" \
  REALITY_SNI="$REALITY_SNI" CERT_CN="$CERT_CN" \
  bash "$SCRIPT" "$@"
}

detect_ip() {
  if [ -n "$SERVER_IP" ]; then echo "$SERVER_IP"; return 0; fi
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "(未设置)"
}
listening() { ss -tuln 2>/dev/null | grep -q ":$1\\b"; }
svc_active() { [ "$(systemctl is-active "$SERVICE" 2>/dev/null)" = "active" ]; }

# ---------- 界面（仿甬哥 sb 面板：块字主标 / 绿菜单 / 状态区） ----------
SEP="$R"   # 分隔线颜色在 COLOR 启用时覆盖
[ "$COLOR" = "1" ] && SEP=$'\033[38;5;203m'
wave() { printf "%s~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~%s\n" "$SEP" "$R"; }
dash() { printf "%s--------------------------------------------------------------%s\n" "$SEP" "$R"; }

banner_art() { # MY BOX 块字主标，每字一色（用 ASCII 占位符，不依赖 locale）
  local M_=("#   #" "## ##" "# # #" "#   #" "#   #")
  local Y_=("#   #" " # # " "  #  " "  #  " "  #  ")
  local B_=("#### " "#   #" "#### " "#   #" "#### ")
  local O_=(" ### " "#   #" "#   #" "#   #" " ### ")
  local X_=("#   #" " # # " "  #  " " # # " "#   #")
  local cols=() r row ch i
  if [ "$COLOR" = "1" ]; then
    cols=($'\033[1;34m' $'\033[1;36m' $'\033[1;35m' $'\033[1;97m' $'\033[1;31m')
  else
    cols=("" "" "" "" "")
  fi
  for r in 0 1 2 3 4; do
    row=" "
    local parts=("${M_[$r]}" "${Y_[$r]}" "${B_[$r]}" "${O_[$r]}" "${X_[$r]}")
    for i in 0 1 2 3 4; do
      row+="${cols[$i]}"
      local s="${parts[$i]}"
      while [ -n "$s" ]; do
        ch="${s:0:1}"; s="${s:1}"
        if [ "$ch" = "#" ]; then row+="██"; else row+="  "; fi
      done
      row+="$R  "
    done
    printf "%s\n" "$row"
  done
}

project_lines() {
  printf "%smybox Github项目%s ： github.com/Xudashu2023/mybox\n" "$B" "$R"
  printf "%s五协议共存脚本%s   ： Vless-reality-vision、Vmess-ws、Hy2、Tuic、Anytls\n" "$B" "$R"
  printf "%s脚本快捷方式%s     ： mybox\n" "$B" "$R"
}

region_of_ip() { # 地区查询（结果按 IP 缓存 7 天，失败显示未知）
  local ip="$1" cache="$DIR/.region" cip="" cdate=0 now
  now="$(date +%s)"
  if [ -f "$cache" ]; then
    cip="$(sed -n '1p' "$cache")"; cdate="$(sed -n '2p' "$cache")"
    if [ "$cip" = "$ip" ] && [ $((now - ${cdate:-0})) -lt 604800 ]; then
      sed -n '3p' "$cache"; return 0
    fi
  fi
  local out
  out="$(curl -s --max-time 3 "http://ip-api.com/json/${ip}?lang=zh-CN&fields=status,country,regionName,city,isp" 2>/dev/null \
    | python3 -c '
import json,sys
try:
  d=json.load(sys.stdin)
  if d.get("status")=="success":
    print(" ".join(x for x in [d.get("country",""), d.get("regionName",""), d.get("city",""), d.get("isp","")] if x))
except Exception: pass' 2>/dev/null)"
  [ -z "$out" ] && out="未知"
  { printf "%s\n%s\n%s\n" "$ip" "$now" "$out" > "$cache"; } 2>/dev/null || true
  echo "$out"
}

core_latest() { # 最新正式版内核（每次面板会话只查一次）
  if [ -z "${CORE_LATEST_CACHE:-}" ]; then
    CORE_LATEST_CACHE="$(curl -fsSL --max-time 3 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tag_name","").lstrip("v"))
except Exception: pass' 2>/dev/null)"
    [ -z "$CORE_LATEST_CACHE" ] && CORE_LATEST_CACHE="未知"
  fi
  echo "$CORE_LATEST_CACHE"
}

status_block() { # 仿 sb：版本行 + VPS 状态 + 节点关键信息
  local cur latest ip ipv6 os virt cc
  cur="$("$BIN" version 2>/dev/null | awk '/version/{print $NF; exit}')"; [ -z "$cur" ] && cur="未安装"
  latest="$(core_latest)"
  ip="$(detect_ip)"
  ipv6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{split($2,a,"/"); print a[1]; exit}')"; [ -z "$ipv6" ] && ipv6="无 IPv6"
  os="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
  virt="$(systemd-detect-virt 2>/dev/null || echo 未知)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"

  printf "当前 mybox 面板版本：%s%s%s（已安装）\n" "$BCYN" "$PANEL_VERSION" "$R"
  printf "当前 Sing-box 面板锁定内核：%s%s%s\n" "$BCYN" "$SB_VERSION" "$R"
  printf "当前 Sing-box 已安装正式版内核：%s%s%s\n" "$BCYN" "$cur" "$R"
  if [ "$latest" != "未知" ] && [ "$latest" != "$cur" ]; then
    printf "检测到最新 Sing-box 正式版内核：%s%s%s（可选 12 → 4 进行更新）\n" "$BYEL" "$latest" "$R"
  fi
  wave
  printf "%sVPS状态如下：%s\n" "$B" "$R"
  printf "系统：%s%s%s  内核：%s  处理器：%s  虚拟化：%s  BBR算法：%s%s%s\n" \
    "$BCYN" "$os" "$R" "$(uname -r)" "$(uname -m)" "$virt" "$BYEL" "$cc" "$R"
  printf "本地IPV4地址：%s%s%s  本地IPV6地址：%s\n" "$BYEL" "$ip" "$R" "$ipv6"
  printf "服务器地区：%s\n" "$(region_of_ip "$ip")"
  printf "Sing-box状态：%s\n" "$(svc_active && echo "${BGRN}运行中${R}" || echo "${BRED}未运行${R}")"
  wave
  printf "%sSing-box节点关键信息如下：%s\n" "$B" "$R"
  local hy2fix="未修复（缺 alpn h3）" hy2col="$BRED"
  if [ -f "$CONF" ] && grep -A6 '"hysteria2"' "$CONF" | grep -q '"h3"'; then hy2fix="已修复（alpn h3）"; hy2col="$BGRN"; fi
  local vmpath="-"; [ -f "$CREDS" ] && vmpath="$(. "$CREDS" 2>/dev/null; echo "${VMESS_PATH:--}")"
  printf "🚀 %sVless-reality 】%s端口：%s%s%s  Reality域名伪装地址：%s\n" "$B" "$R" "$BYEL" "$PORT_VLESS" "$R" "$REALITY_SNI"
  printf "🚀 %sVmess-ws      】%s端口：%s%s%s  证书形式：TLS关闭  路径：%s\n" "$B" "$R" "$BYEL" "$PORT_VMESS" "$R" "$vmpath"
  printf "🚀 %sHysteria-2    】%s端口：%s%s%s  证书形式：自签证书  握手修复：%s%s%s\n" "$B" "$R" "$BYEL" "$PORT_HY2" "$R" "$hy2col" "$hy2fix" "$R"
  printf "🚀 %sTuic-v5       】%s端口：%s%s%s  证书形式：自签证书  拥塞控制：bbr\n" "$B" "$R" "$BYEL" "$PORT_TUIC" "$R"
  printf "🚀 %sAnytls        】%s端口：%s%s%s  证书形式：自签证书\n" "$B" "$R" "$BYEL" "$PORT_ANYTLS" "$R"
  wave
  if ss -tuln 2>/dev/null | grep -q ':40000'; then
    printf "WARP-plus-Socks5状态：%s已启动（127.0.0.1:40000）%s\n" "$BGRN" "$R"
  else
    printf "WARP-plus-Socks5状态：%s未启动%s\n" "$BYEL" "$R"
  fi
  local mem_pct disk_pct
  mem_pct="$(free 2>/dev/null | awk '/^Mem:/{printf "%d", $3*100/$2}')"
  disk_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  [ -n "${mem_pct:-}" ]  && printf "内存占用：%s\n" "$(bar "$mem_pct")"
  [ -n "${disk_pct:-}" ] && printf "磁盘占用：%s\n" "$(bar "$disk_pct")"
  dash
}

# ---------- 节点与配置 ----------
show_links() {
  [ -z "$SERVER_IP" ] && warn "未设置 SERVER_IP，链接里的 IP 可能不准（菜单 11 里可填服务器公网 IP）。"
  run_script show-links
}

show_qr() {
  if ! command -v qrencode >/dev/null 2>&1; then
    warn "未安装 qrencode，装一下就能在终端里扫码导入："
    echo "  apt-get install -y qrencode"
    return 0
  fi
  [ -f "$DIR/client/links.txt" ] || { err "链接文件不存在，先跑一次菜单 1。"; return 0; }
  echo "选择要显示二维码的节点："
  local i=1 names=("mybox-vless" "mybox-vmess" "mybox-anytls" "mybox-hy2" "mybox-tuic") sel
  for n in "${names[@]}"; do echo "  $i) $n"; i=$((i+1)); done
  printf "编号 [1-5]: "; read -r sel || return 0
  case "$sel" in 1|2|3|4|5) ;; *) err "无效编号"; return 0;; esac
  local link
  link="$(sed -n "${sel}p" "$DIR/client/links.txt")"
  printf "\n%s%s%s\n" "$B" "${names[$((sel-1))]}" "$R"
  qrencode -t ANSIUTF8 "$link"
}

show_clash() {
  if [ -f "$DIR/client/clash.yaml" ]; then cat "$DIR/client/clash.yaml"
  else err "还没有 Clash 配置，先跑一次菜单 1 或重装。"; fi
}

# ---------- 全协议本机自测 ----------
self_test() {
  [ -x "$BIN" ] || { err "找不到 sing-box 二进制 $BIN"; return 0; }
  [ -f "$CREDS" ] || { err "找不到凭据文件 $CREDS"; return 0; }
  svc_active || { err "mybox 服务未运行，先启动服务（菜单 5）。"; return 0; }
  echo "将逐个协议在本机回连测试（经节点访问 ipify，看出口与延迟）…"
  local tmp; tmp="$(mktemp -d)"
  # 生成五份客户端配置（python3 是 mybox 的既有依赖）
  CREDS="$CREDS" TESTDIR="$tmp" \
  PORT_VLESS="$PORT_VLESS" PORT_VMESS="$PORT_VMESS" PORT_ANYTLS="$PORT_ANYTLS" \
  PORT_HY2="$PORT_HY2" PORT_TUIC="$PORT_TUIC" \
  REALITY_SNI="$REALITY_SNI" CERT_CN="$CERT_CN" \
  python3 - <<'PY'
import json, os, re, sys
creds = {}
for line in open(os.environ["CREDS"]):
    m = re.match(r"(\w+)='([^']*)'", line.strip())
    if m: creds[m.group(1)] = m.group(2)
e = os.environ
def cfg(ob, port):
    return {"log": {"level": "error"},
            "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 18101}],
            "outbounds": [dict(ob, server="127.0.0.1", server_port=port)],
            "route": {"final": ob["tag"]}}
tests = {
 "vless": {"type": "vless", "tag": "o", "uuid": creds["UUID_VLESS"], "flow": "xtls-rprx-vision",
           "tls": {"enabled": True, "server_name": e["REALITY_SNI"],
                   "reality": {"enabled": True, "public_key": creds["REALITY_PUB"], "short_id": creds["SHORT_ID"]},
                   "utls": {"enabled": True, "fingerprint": "chrome"}}},
 "vmess": {"type": "vmess", "tag": "o", "uuid": creds["UUID_VMESS"], "security": "auto", "alter_id": 0,
           "transport": {"type": "ws", "path": creds["VMESS_PATH"], "headers": {"Host": [e["CERT_CN"]]}}},
 "anytls": {"type": "anytls", "tag": "o", "password": creds["PASS_ANYTLS"],
            "tls": {"enabled": True, "server_name": e["CERT_CN"], "insecure": True}},
 "hy2": {"type": "hysteria2", "tag": "o", "password": creds["PASS_HY2"],
         "tls": {"enabled": True, "server_name": e["CERT_CN"], "insecure": True}},
 "tuic": {"type": "tuic", "tag": "o", "uuid": creds["UUID_TUIC"], "password": creds["PASS_TUIC"],
          "congestion_control": "bbr",
          "tls": {"enabled": True, "server_name": e["CERT_CN"], "insecure": True, "alpn": ["h3"]}},
}
ports = {"vless": int(e["PORT_VLESS"]), "vmess": int(e["PORT_VMESS"]), "anytls": int(e["PORT_ANYTLS"]),
         "hy2": int(e["PORT_HY2"]), "tuic": int(e["PORT_TUIC"])}
for name, ob in tests.items():
    with open(os.path.join(e["TESTDIR"], name + ".json"), "w") as f:
        json.dump(cfg(ob, ports[name]), f)
print("generated")
PY
  [ $? -ne 0 ] && { err "生成测试配置失败"; rm -rf "$tmp"; return 0; }
  printf "\n  %-8s %-10s %-18s %s\n" "协议" "结果" "出口 IP" "延迟"
  hr
  local name label
  for name in vless vmess anytls hy2 tuic; do
    case "$name" in
      vless) label="VLESS";; vmess) label="VMess";; anytls) label="AnyTLS";;
      hy2) label="Hy2";; tuic) label="TUIC";;
    esac
    "$BIN" run -c "$tmp/$name.json" >/dev/null 2>&1 &
    local pid=$! i
    for i in $(seq 1 30); do ss -tln 2>/dev/null | grep -q ':18101\b' && break; sleep 0.2; done
    local out t0 t1 ms
    t0=$(date +%s%N)
    out="$(curl -s --max-time 10 -x socks5h://127.0.0.1:18101 https://api.ipify.org 2>/dev/null)"
    t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    if [ -n "$out" ]; then
      printf "  %-8s %s✓ 通%s     %-18s %s ms\n" "$label" "$BGRN" "$R" "$out" "$ms"
    else
      printf "  %-8s %s✗ 不通%s\n" "$label" "$BRED" "$R"
    fi
    sleep 0.3
  done
  rm -rf "$tmp"
  echo
  echo "${D}注：本机回连只验证服务端配置与出站；你客户端不通多半是握手/网络问题，对照仪表盘上的 Hy2 h3 修复标记看。${R}"
}

# ---------- 服务与日志 ----------
service_menu() {
  while true; do
    hr
    printf "%s服务管理%s  当前：%s\n" "$BCYN" "$R" "$(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)"
    cat <<EOF
  1) 启动
  2) 停止
  3) 重启
  4) 查看状态详情
  0) 返回
EOF
    printf "请选择 [0-4]: "; read -r c || return 0
    case "$c" in
      1) systemctl start "$SERVICE";   ok "已启动：$(systemctl is-active "$SERVICE" 2>/dev/null)" ;;
      2) confirm "停止后所有节点立即断线，继续？" && { systemctl stop "$SERVICE"; warn "已停止"; } ;;
      3) systemctl restart "$SERVICE"; ok "已重启：$(systemctl is-active "$SERVICE" 2>/dev/null)" ;;
      4) systemctl --no-pager status "$SERVICE" 2>/dev/null | head -n 15; pause ;;
      0) return 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

log_menu() {
  while true; do
    hr
    printf "%s日志%s（journalctl -u %s）\n" "$BCYN" "$R" "$SERVICE"
    cat <<EOF
  1) 最近 50 行
  2) 只看错误
  3) 实时跟踪（Ctrl+C 退出跟踪）
  0) 返回
EOF
    printf "请选择 [0-3]: "; read -r c || return 0
    case "$c" in
      1) journalctl -u "$SERVICE" --no-pager -n 50; pause ;;
      2) journalctl -u "$SERVICE" --no-pager -n 100 | grep -iE 'error|fail|warn' || echo "(无错误记录)"; pause ;;
      3) journalctl -u "$SERVICE" -f -n 20 ;;
      0) return 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

# ---------- 流量与系统 ----------
show_traffic() {
  if command -v vnstat >/dev/null 2>&1; then
    vnstat --oneline 2>/dev/null || vnstat 2>/dev/null | head -n 20
  else
    local iface rx tx
    iface="$(ip route 2>/dev/null | awk '/default/{print $5; exit}')"
    rx="$(cat /proc/net/dev 2>/dev/null | awk -v i="$iface" '$1 ~ i {print $2}')"
    tx="$(cat /proc/net/dev 2>/dev/null | awk -v i="$iface" '$1 ~ i {print $10}')"
    echo "网卡 $iface 自开机以来流量（装 vnstat 可看按月统计）："
    awk -v r="${rx:-0}" -v t="${tx:-0}" 'BEGIN{printf "  ↓ 接收 %.2f GB\n  ↑ 发送 %.2f GB\n", r/1073741824, t/1073741824}'
    echo "${D}提示：apt-get install -y vnstat 后这里能看月流量。${R}"
  fi
}

show_sysinfo() {
  printf "%s系统%s %s\n" "$D" "$R" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}")  $(uname -r)  $(uname -m)"
  printf "%s运行%s %s\n" "$D" "$R" "$(uptime -p 2>/dev/null || uptime)"
  printf "%s负载%s %s\n" "$D" "$R" "$(awk '{print $1, $2, $3}' /proc/loadavg)  （$(nproc 2>/dev/null || echo '?') 核）"
  free -h 2>/dev/null | awk 'NR<=2'
  df -h / 2>/dev/null | awk 'NR<=2'
  echo "${D}内存占用前五进程：${R}"
  ps aux --sort=-%mem 2>/dev/null | head -n 6
}

test_egress() {
  printf "服务器直连出口：%s%s%s\n" "$B" "$(curl -s --max-time 10 https://api.ipify.org || echo 请求失败)" "$R"
  if ss -tuln 2>/dev/null | grep -q ':40000'; then
    printf "经 WARP(127.0.0.1:40000)：%s%s%s\n" "$B" "$(curl -s --max-time 10 -x socks5h://127.0.0.1:40000 https://api.ipify.org || echo 请求失败)" "$R"
  fi
}

# ---------- 设置 ----------
edit_settings() {
  echo "直接回车 = 保持不变。改完保存到 $PANEL_CONF 并可立即重跑 install 生效。"
  echo "${D}注意：改端口后客户端链接会变；改 REALITY_SNI / 证书 CN 后所有客户端都要换新链接。${R}"
  local v
  printf "服务器公网 IP [%s]: " "$(detect_ip)";        read -r v || return 0; [ -n "$v" ] && SERVER_IP="$v"
  printf "VLESS 端口 [%s]: "  "$PORT_VLESS";  read -r v || return 0; [ -n "$v" ] && PORT_VLESS="$v"
  printf "VMess 端口 [%s]: "  "$PORT_VMESS";  read -r v || return 0; [ -n "$v" ] && PORT_VMESS="$v"
  printf "AnyTLS 端口 [%s]: " "$PORT_ANYTLS"; read -r v || return 0; [ -n "$v" ] && PORT_ANYTLS="$v"
  printf "Hy2 端口 [%s]: "    "$PORT_HY2";    read -r v || return 0; [ -n "$v" ] && PORT_HY2="$v"
  printf "TUIC 端口 [%s]: "   "$PORT_TUIC";   read -r v || return 0; [ -n "$v" ] && PORT_TUIC="$v"
  printf "REALITY SNI [%s]: " "$REALITY_SNI"; read -r v || return 0; [ -n "$v" ] && REALITY_SNI="$v"
  printf "证书 CN [%s]: "     "$CERT_CN";     read -r v || return 0; [ -n "$v" ] && CERT_CN="$v"
  save_panel_conf && ok "已保存"
  if confirm "现在重跑 install 让新设置生效（凭据不变）？"; then run_script install; else echo "下次重装时生效。"; fi
}

# ---------- 更新中心 ----------
update_menu() {
  while true; do
    hr
    printf "%s更新中心%s\n" "$BCYN" "$R"
    cat <<EOF
  1) 用本机脚本重装（应用已有修复，凭据复用）
  2) 从 GitHub 拉最新安装脚本并重装
  3) 更新面板自身（从 GitHub 拉 mybox-panel.sh）
  4) Sing-box 内核版本管理（更新 / 切换 / 指定版本）
  0) 返回
EOF
    printf "请选择 [0-4]: "; read -r c || return 0
    case "$c" in
      1) confirm "重跑 install？（凭据复用，服务会重启）" && run_script install ;;
      2)
        if curl -fsSL "$RAW_BASE/mybox-install.sh" -o "$SCRIPT.new" && bash -n "$SCRIPT.new"; then
          mv "$SCRIPT.new" "$SCRIPT"; ok "脚本已更新到最新版"
          confirm "现在重装？" && run_script install
        else err "下载或校验失败，未替换现有脚本"; rm -f "$SCRIPT.new"; fi
        ;;
      3)
        if curl -fsSL "$RAW_BASE/mybox-panel.sh" -o "/tmp/mybox-panel.new" && bash -n /tmp/mybox-panel.new; then
          install -m 755 /tmp/mybox-panel.new "$PANEL_SELF"; rm -f /tmp/mybox-panel.new
          ok "面板已更新，重新运行 mybox 生效"
          exit 0
        else err "下载或校验失败，面板未更新"; rm -f /tmp/mybox-panel.new; fi
        ;;
      4) kernel_menu ;;
      0) return 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

# ---------- Sing-box 内核版本 ----------
kernel_current() { "$BIN" version 2>/dev/null | awk '/version/{print $NF; exit}'; }

switch_kernel() { # switch_kernel 目标版本（不带 v 前缀）
  local want="$1" arch name api digest tmp newbin cur
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64) arch=arm64 ;;
    *) err "不支持的架构：$(uname -m)"; return 0 ;;
  esac
  name="sing-box-${want}-linux-${arch}.tar.gz"
  api="https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${want}"
  echo "获取 v${want} 官方发布摘要…"
  digest="$(curl -fsSL "$api" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
name=sys.argv[1]
for a in d.get("assets",[]):
    if a["name"]==name: print((a.get("digest") or "").removeprefix("sha256:")); break
' "$name")"
  [ -n "$digest" ] || { err "取不到 v${want} 的官方摘要（版本不存在或网络问题），已中止"; return 0; }
  tmp="$(mktemp -d)"
  echo "下载 $name …"
  if ! curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${want}/${name}" -o "$tmp/pkg.tar.gz"; then
    err "下载失败，已中止"; rm -rf "$tmp"; return 0
  fi
  if ! echo "$digest  $tmp/pkg.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
    err "SHA256 校验不通过，已中止（文件未替换）"; rm -rf "$tmp"; return 0
  fi
  ok "官方摘要校验通过"
  tar xzf "$tmp/pkg.tar.gz" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 0; }
  newbin="$tmp/sing-box-${want}-linux-${arch}/sing-box"
  [ -x "$newbin" ] || { err "压缩包里找不到 sing-box 二进制"; rm -rf "$tmp"; return 0; }
  if [ -f "$CONF" ] && ! "$newbin" check -c "$CONF" >/dev/null 2>&1; then
    err "新版本与现有配置不兼容（sing-box check 未通过），已中止，旧版本未动"
    rm -rf "$tmp"; return 0
  fi
  cur="$(kernel_current)"
  [ -x "$BIN" ] && cp -a "$BIN" "$BIN.bak"
  install -m 755 "$newbin" "$BIN"
  rm -rf "$tmp"
  systemctl restart "$SERVICE" 2>/dev/null
  sleep 1
  if svc_active && [ "$(kernel_current)" = "$want" ]; then
    SB_VERSION="$want"; save_panel_conf
    ok "已切换到 sing-box v${want}（原 v${cur:-未知}），并写入面板设置，后续重装保持此版本"
  else
    err "新版本启动失败，正在回滚…"
    [ -f "$BIN.bak" ] && install -m 755 "$BIN.bak" "$BIN"
    systemctl restart "$SERVICE" 2>/dev/null
    err "已回滚到原版本：$(kernel_current)"
  fi
}

kernel_menu() {
  while true; do
    hr
    printf "%sSing-box 内核%s  当前运行：%s%s%s   面板锁定：v%s\n" \
      "$BCYN" "$R" "$B" "$(kernel_current || echo 未安装)" "$R" "$SB_VERSION"
    cat <<EOF
  1) 更新到最新版（查 GitHub 最新 release）
  2) 指定版本切换（从最近版本里选，或手动输入）
  3) 恢复为面板锁定版本（v$SB_VERSION）
  0) 返回
EOF
    printf "请选择 [0-3]: "; read -r c || return 0
    case "$c" in
      1)
        local latest
        latest="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null)"
        [ -n "$latest" ] || { err "查不到最新版本（网络问题）"; continue; }
        echo "最新版：v${latest}，当前：v$(kernel_current)"
        [ "$latest" = "$(kernel_current)" ] && { ok "已经是最新版"; continue; }
        confirm "更新到 v${latest}？" && switch_kernel "$latest"
        ;;
      2)
        echo "最近版本："
        local tags i=1 t picked
        tags="$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=8" 2>/dev/null \
          | python3 -c 'import json,sys
try:
  for r in json.load(sys.stdin): print(r.get("tag_name","").lstrip("v"))
except Exception: pass' 2>/dev/null)"
        if [ -n "$tags" ]; then
          while IFS= read -r t; do echo "  $i) v$t"; i=$((i+1)); done <<< "$tags"
        else
          warn "拉不到版本列表，可直接手动输入版本号"
        fi
        printf "输入编号或完整版本号（如 1.13.3），回车取消: "
        read -r picked || continue
        [ -z "$picked" ] && continue
        if [[ "$picked" =~ ^[0-9]+$ ]] && [ -n "$tags" ]; then
          picked="$(sed -n "${picked}p" <<< "$tags")"
          [ -n "$picked" ] || { err "编号超出范围"; continue; }
        fi
        picked="${picked#v}"
        confirm "切换到 v${picked}？" && switch_kernel "$picked"
        ;;
      3) [ "$(kernel_current)" = "$SB_VERSION" ] && ok "已在锁定版本" || { confirm "恢复为 v${SB_VERSION}？" && switch_kernel "$SB_VERSION"; } ;;
      0) return 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

# ---------- BBR + FQ 加速（内核原版） ----------
bbr_status() {
  local cc av qd iface tcq
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  av="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '?')"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  iface="$(ip route 2>/dev/null | awk '/default/{print $5; exit}')"
  tcq="$(tc qdisc show dev "$iface" 2>/dev/null | head -n 1)"
  printf "当前拥塞控制：%s%s%s（可选：%s）\n" "$B" "$cc" "$R" "$av"
  printf "默认队列规则：%s%s%s\n" "$B" "$qd" "$R"
  [ -n "$tcq" ] && printf "网卡 %s 队列：%s\n" "$iface" "$tcq"
  if [ "$cc" = "bbr" ] && [ "$qd" = "fq" ]; then ok "BBR + FQ 已开启（内核原版）"; else warn "尚未开启 BBR + FQ"; fi
}

bbr_on() {
  confirm "一键开启内核原版 BBR + FQ？（写 /etc/sysctl.d/99-mybox-bbr.conf，立即生效，重启不丢）" || { echo "已取消"; return 0; }
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    err "当前内核没有 bbr 模块（容器/OpenVZ 内核常见），无法开启"; return 0
  fi
  echo "tcp_bbr" > /etc/modules-load.d/mybox-bbr.conf 2>/dev/null || true
  cat > /etc/sysctl.d/99-mybox-bbr.conf <<'EOF'
# mybox panel: BBR + FQ
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p /etc/sysctl.d/99-mybox-bbr.conf >/dev/null 2>&1
  local iface; iface="$(ip route 2>/dev/null | awk '/default/{print $5; exit}')"
  [ -n "$iface" ] && tc qdisc replace dev "$iface" root fq 2>/dev/null || true
  bbr_status
}

bbr_off() {
  confirm "关闭 BBR + FQ，恢复 cubic + fq_codel？" || { echo "已取消"; return 0; }
  rm -f /etc/sysctl.d/99-mybox-bbr.conf /etc/modules-load.d/mybox-bbr.conf
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
  sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
  local iface; iface="$(ip route 2>/dev/null | awk '/default/{print $5; exit}')"
  [ -n "$iface" ] && tc qdisc replace dev "$iface" root fq_codel 2>/dev/null || true
  bbr_status
}

bbr_menu() {
  while true; do
    hr
    printf "%s网络加速 · 原版 BBR + FQ%s\n" "$BCYN" "$R"
    bbr_status
    cat <<EOF
  1) 一键开启 BBR + FQ
  2) 关闭（恢复 cubic + fq_codel）
  0) 返回
EOF
    printf "请选择 [0-2]: "; read -r c || return 0
    case "$c" in
      1) bbr_on ;;
      2) bbr_off ;;
      0) return 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

# ---------- 备份 / 恢复 ----------
backup_menu() {
  while true; do
    hr
    printf "%s备份 / 恢复%s（范围：整个 /etc/mybox，含凭据与配置）\n" "$BCYN" "$R"
    cat <<EOF
  1) 立即备份
  2) 从备份恢复
  0) 返回
EOF
    printf "请选择 [0-2]: "; read -r c || return 0
    case "$c" in
      1)
        mkdir -p "$BACKUP_DIR"
        local f="$BACKUP_DIR/mybox-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar czf "$f" -C / "etc/mybox" 2>/dev/null && { chmod 600 "$f"; ok "已备份：$f"; } || err "备份失败"
        ;;
      2)
        local files=() i sel
        for f in "$BACKUP_DIR"/*.tar.gz; do [ -f "$f" ] && files+=("$f"); done
        [ "${#files[@]}" -eq 0 ] && { warn "还没有备份"; continue; }
        i=1; for f in "${files[@]}"; do echo "  $i) $f"; i=$((i+1)); done
        printf "选择要恢复的编号 [1-%s，0 取消]: " "${#files[@]}"; read -r sel || continue
        [ "$sel" = "0" ] && continue
        case "$sel" in ''|*[!0-9]*) err "无效编号"; continue;; esac
        [ "$sel" -ge 1 ] && [ "$sel" -le "${#files[@]}" ] || { err "无效编号"; continue; }
        warn "恢复将覆盖当前 /etc/mybox（含凭据，节点链接会变回备份时的）。"
        if confirm "确定恢复 ${files[$((sel-1))]}？"; then
          tar xzf "${files[$((sel-1))]}" -C / && systemctl restart "$SERVICE" \
            && ok "已恢复并重启服务" || err "恢复失败，请检查备份文件"
        fi
        ;;
      0) return 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

uninstall_box() {
  warn "卸载会删除 mybox 服务、/etc/mybox 配置与凭据，五条节点链接随即作废（不可恢复）。"
  confirm "确定卸载？" || { echo "已取消"; return 0; }
  confirm "再确认一次：真的卸载？" || { echo "已取消"; return 0; }
  run_script uninstall
  echo "面板命令保留，如需删除：rm $PANEL_SELF"
}

# ---------- 主菜单 ----------
menu_list() {
  local G="$GRN" GB="$BGRN"
  printf "%s 1. 查看节点链接%s\n" "$GB" "$R"
  printf "%s 2. 二维码导入 [手机扫码导入节点]%s\n" "$G" "$R"
  printf "%s 3. 查看 Clash 配置%s\n" "$G" "$R"
  printf "%s 4. 全协议自测 [逐个回连测通断/出口/延迟]%s\n" "$G" "$R"
  dash
  printf "%s 5. 服务管理 [启动/停止/重启 Sing-box]%s\n" "$G" "$R"
  printf "%s 6. 查看 Sing-box 运行日志%s\n" "$G" "$R"
  printf "%s 7. 查看流量统计%s\n" "$G" "$R"
  printf "%s 8. 查看系统信息%s\n" "$G" "$R"
  printf "%s 9. 出口测试 [直连/WARP 出口 IP]%s\n" "$G" "$R"
  printf "%s10. 一键原版 BBR+FQ 加速%s\n" "$G" "$R"
  dash
  printf "%s11. 修改设置 [IP优先/端口/SNI/证书域名]%s\n" "$G" "$R"
  printf "%s12. 更新中心 [脚本/面板/更新切换指定内核版本]%s\n" "$G" "$R"
  printf "%s13. 备份/恢复 [配置与凭据打包]%s\n" "$G" "$R"
  printf "%s14. 卸载 Sing-box（mybox）%s\n" "$G" "$R"
  dash
  printf "%s 0. 退出脚本%s\n" "$G" "$R"
}

while true; do
banner_art
wave
project_lines
wave
menu_list
wave
status_block
printf "%s请输入数字 [0-14]：%s " "$BYEL" "$R"
read -r choice || exit 0
case "$choice" in
1) show_links; pause;;
2) show_qr; pause;;
3) show_clash; pause;;
4) self_test;;
5) service_menu;;
6) log_menu;;
7) show_traffic; pause;;
8) show_sysinfo; pause;;
9) test_egress; pause;;
10) bbr_menu;;
11) edit_settings; pause;;
12) update_menu;;
13) backup_menu;;
14) uninstall_box; pause;;
0) printf "%s再见 👋%s\n" "$D" "$R"; exit 0;;
*) err "无效选择";;
esac
done
