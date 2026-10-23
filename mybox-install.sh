#!/usr/bin/env bash
# =============================================================================
# mybox —— 个人纯净版 sing-box 五协议安装脚本
#
# 只做三件事：装内核、写配置、起服务。
# 没有菜单、没有订阅托管、没有 Argo/WARP/TG 推送、没有自更新、没有定时重启。
#
# 协议（端口保持与现有订阅一致，凭据每个协议独立生成）：
#   VLESS-REALITY (TCP) / VMess-WS (TCP) / AnyTLS (TCP)
#   Hysteria2 (UDP)     / TUIC (UDP)
#
# 用法：
#   sudo bash mybox-install.sh install      安装或更新（可重复运行，凭据不重置）
#   sudo bash mybox-install.sh uninstall    卸载服务与本脚本生成的文件
#        bash mybox-install.sh print-config 只打印将要生成的 config.json（免 root 预览）
#        bash mybox-install.sh show-links   根据已保存凭据重新打印分享链接
#
# 可用环境变量覆盖（一般不用改）：
#   SB_VERSION   sing-box 版本（默认锁定 1.14.3，不追 latest）
#   SERVER_IP    服务器公网 IP（默认自动探测，探测失败时必须手动指定）
#   PORT_VLESS / PORT_VMESS / PORT_ANYTLS / PORT_HY2 / PORT_TUIC
#   REALITY_SNI  默认 apple.com ；CERT_CN 自签证书 CN，默认 www.bing.com
#
# 凭据保存在 /etc/mybox/credentials.env（权限 600），这是全套节点的总钥匙，
# 泄露等于五协议全泄露，请按私钥级别保管，不要外发。
# =============================================================================
set -euo pipefail

SB_VERSION="${SB_VERSION:-1.14.3}"
DIR="/etc/mybox"
CONF="$DIR/config.json"
CREDS="$DIR/credentials.env"
CERT_FILE="${CERT_FILE:-$DIR/cert.pem}"
KEY_FILE="${KEY_FILE:-$DIR/private.key}"
BIN="/usr/local/bin/sing-box"
UNIT="/etc/systemd/system/mybox.service"

PORT_VLESS="${PORT_VLESS:-40136}"
PORT_VMESS="${PORT_VMESS:-2082}"
PORT_ANYTLS="${PORT_ANYTLS:-20917}"
PORT_HY2="${PORT_HY2:-41413}"
PORT_TUIC="${PORT_TUIC:-59899}"
REALITY_SNI="${REALITY_SNI:-apple.com}"
CERT_CN="${CERT_CN:-www.bing.com}"

log()  { printf '\033[32m[mybox]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[mybox]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[mybox] 错误：\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 运行（sudo bash $0 $1）"; }
have() { command -v "$1" >/dev/null 2>&1; }

arch_map() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

install_deps() {
  local missing=()
  for c in curl tar openssl python3 sha256sum; do have "$c" || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] && return 0
  log "安装缺失依赖：${missing[*]}"
  if [ -f /etc/debian_version ] && have apt-get; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      curl tar openssl python3 ca-certificates >/dev/null
  else
    die "缺少依赖 ${missing[*]}，且不是 Debian/Ubuntu，请手动安装后重试"
  fi
}

gen_uuid() {
  if [ -x "$BIN" ]; then "$BIN" generate uuid;
  elif [ -f /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid;
  else python3 -c 'import uuid;print(uuid.uuid4())'; fi
}

# ---------- 凭据：首次生成并落盘（600），之后重跑直接复用 ----------
load_or_create_creds() {
  if [ -f "$CREDS" ]; then
    # shellcheck disable=SC1090
    set -a; . "$CREDS"; set +a
    log "复用已有凭据（$CREDS）"
    return 0
  fi
  UUID_VLESS="$(gen_uuid)"
  UUID_VMESS="$(gen_uuid)"
  UUID_TUIC="$(gen_uuid)"
  PASS_ANYTLS="$(openssl rand -base64 18 | tr -d '\n')"
  PASS_HY2="$(openssl rand -base64 18 | tr -d '\n')"
  PASS_TUIC="$(openssl rand -base64 18 | tr -d '\n')"
  local kp priv pub
  kp="$("$BIN" generate reality-keypair)"
  priv="$(printf '%s' "$kp" | awk '/PrivateKey/{print $2}')"
  pub="$(printf '%s' "$kp" | awk '/PublicKey/{print $2}')"
  REALITY_PRIV="$priv"; REALITY_PUB="$pub"
  SHORT_ID="$(openssl rand -hex 4)"
  VMESS_PATH="/$(openssl rand -hex 8)-vm"
  umask 077
  {
    printf "UUID_VLESS='%s'\n"    "$UUID_VLESS"
    printf "UUID_VMESS='%s'\n"    "$UUID_VMESS"
    printf "UUID_TUIC='%s'\n"     "$UUID_TUIC"
    printf "PASS_ANYTLS='%s'\n"   "$PASS_ANYTLS"
    printf "PASS_HY2='%s'\n"      "$PASS_HY2"
    printf "PASS_TUIC='%s'\n"     "$PASS_TUIC"
    printf "REALITY_PRIV='%s'\n"  "$REALITY_PRIV"
    printf "REALITY_PUB='%s'\n"   "$REALITY_PUB"
    printf "SHORT_ID='%s'\n"      "$SHORT_ID"
    printf "VMESS_PATH='%s'\n"    "$VMESS_PATH"
  } > "$CREDS"
  chmod 600 "$CREDS"
  set -a; . "$CREDS"; set +a
  log "已生成独立凭据并保存到 $CREDS（600）"
}

# ---------- 内核：固定版本 + 按 GitHub 官方摘要校验 SHA256 ----------
install_core() {
  if [ -x "$BIN" ] && [ "$("$BIN" version 2>/dev/null | awk '/version/{print $NF}')" = "$SB_VERSION" ]; then
    log "sing-box $SB_VERSION 已安装，跳过下载"
    return 0
  fi
  local arch name url api digest tmp
  arch="$(arch_map)"
  name="sing-box-${SB_VERSION}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${name}"
  api="https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${SB_VERSION}"
  log "获取官方发布摘要……"
  digest="$(curl -fsSL "$api" | python3 -c '
import json,sys
d=json.load(sys.stdin)
name=sys.argv[1]
for a in d.get("assets",[]):
    if a["name"]==name:
        print((a.get("digest") or "").removeprefix("sha256:")); break
' "$name")"
  [ -n "$digest" ] || die "无法从 GitHub 官方 API 取得 $name 的 SHA256 摘要，已中止（不做无校验安装）"
  tmp="$(mktemp -d)"
  log "下载 sing-box $SB_VERSION（$arch）……"
  curl -fL --retry 2 -o "$tmp/$name" "$url"
  echo "$digest  $tmp/$name" | sha256sum -c - >/dev/null || { rm -rf "$tmp"; die "SHA256 校验不通过，已中止"; }
  log "SHA256 校验通过"
  tar xzf "$tmp/$name" -C "$tmp"
  install -m 0755 "$tmp/sing-box-${SB_VERSION}-linux-${arch}/sing-box" "$BIN"
  rm -rf "$tmp"
  log "内核已安装：$("$BIN" version | head -n1)"
}

make_cert() {
  if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ]; then return 0; fi
  log "生成自签证书（CN=$CERT_CN，有效期 10 年）……"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$CERT_CN" 2>/dev/null
  chmod 600 "$KEY_FILE"
}

# ---------- 配置生成（结构已按 sing-box 1.14 官方二进制实测校验） ----------
write_config() {
  python3 - "$CONF" <<'PY'
import json, os, sys
def e(k): return os.environ[k]
tls = {"enabled": True,
       "certificate_path": os.environ.get("CERT_FILE", "/etc/mybox/cert.pem"),
       "key_path": os.environ.get("KEY_FILE", "/etc/mybox/private.key")}
cfg = {
  "log": {"level": "info", "timestamp": True},
  "dns": {"servers": [{"type": "local", "tag": "local"}]},
  "inbounds": [
    {"type": "vless", "tag": "vless-in", "listen": "::",
     "listen_port": int(e("PORT_VLESS")),
     "users": [{"uuid": e("UUID_VLESS"), "flow": "xtls-rprx-vision"}],
     "tls": {"enabled": True, "server_name": e("REALITY_SNI"),
             "reality": {"enabled": True,
                         "handshake": {"server": e("REALITY_SNI"), "server_port": 443},
                         "private_key": e("REALITY_PRIV"),
                         "short_id": [e("SHORT_ID")]}}},
    {"type": "vmess", "tag": "vmess-in", "listen": "::",
     "listen_port": int(e("PORT_VMESS")),
     "users": [{"uuid": e("UUID_VMESS")}],
     "transport": {"type": "ws", "path": e("VMESS_PATH")}},
    {"type": "anytls", "tag": "anytls-in", "listen": "::",
     "listen_port": int(e("PORT_ANYTLS")),
     "users": [{"password": e("PASS_ANYTLS")}], "tls": tls},
    {"type": "hysteria2", "tag": "hy2-in", "listen": "::",
     "listen_port": int(e("PORT_HY2")),
     "users": [{"password": e("PASS_HY2")}], "tls": tls},
    {"type": "tuic", "tag": "tuic-in", "listen": "::",
     "listen_port": int(e("PORT_TUIC")),
     "users": [{"uuid": e("UUID_TUIC"), "password": e("PASS_TUIC")}],
     "congestion_control": "bbr",
     "tls": {**tls, "alpn": ["h3"]}},
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"default_domain_resolver": "local", "final": "direct"},
}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
print("config written:", sys.argv[1])
PY
}

detect_ip() {
  if [ -n "${SERVER_IP:-}" ]; then echo "$SERVER_IP"; return 0; fi
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

# ---------- 客户端产物：链接 + 一份 Clash 配置，只写到本机目录 ----------
write_client_files() {
  local ip="$1" outdir="$DIR/client"
  mkdir -p "$outdir"
  # 客户端生成靠环境变量传参，这里统一导出，避免 show-links 路径下端口为 None
  export PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC REALITY_SNI CERT_CN
  export UUID_VLESS UUID_VMESS UUID_TUIC PASS_ANYTLS PASS_HY2 PASS_TUIC
  export REALITY_PUB SHORT_ID VMESS_PATH
  SERVER_IP_OUT="$ip" python3 - "$outdir" <<'PY'
import base64, json, os, sys
outdir = sys.argv[1]
e = os.environ.get
ip = e("SERVER_IP_OUT")
def q(s):  # URL 里密码可能含 +/=，做百分号编码
    from urllib.parse import quote
    return quote(s, safe="")
vmess_obj = {"v": "2", "ps": "mybox-vmess", "add": ip, "port": str(e("PORT_VMESS")),
             "id": e("UUID_VMESS"), "aid": "0", "net": "ws",
             "path": e("VMESS_PATH"), "host": e("CERT_CN"), "tls": ""}
links = [
 f"vless://{e('UUID_VLESS')}@{ip}:{e('PORT_VLESS')}?encryption=none&flow=xtls-rprx-vision"
 f"&security=reality&sni={e('REALITY_SNI')}&fp=chrome&pbk={e('REALITY_PUB')}"
 f"&sid={e('SHORT_ID')}&type=tcp&headerType=none#mybox-vless",
 "vmess://" + base64.b64encode(json.dumps(vmess_obj).encode()).decode(),
 f"anytls://{q(e('PASS_ANYTLS'))}@{ip}:{e('PORT_ANYTLS')}/?insecure=1&sni={e('CERT_CN')}#mybox-anytls",
 f"hysteria2://{q(e('PASS_HY2'))}@{ip}:{e('PORT_HY2')}/?insecure=1&sni={e('CERT_CN')}#mybox-hy2",
 f"tuic://{e('UUID_TUIC')}:{q(e('PASS_TUIC'))}@{ip}:{e('PORT_TUIC')}"
 f"?congestion_control=bbr&alpn=h3&sni={e('CERT_CN')}&allow_insecure=1#mybox-tuic",
]
open(os.path.join(outdir, "links.txt"), "w").write("\n".join(links) + "\n")

def yq(s): return "'" + str(s).replace("'", "''") + "'"
clash = f"""mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

proxies:
  - name: mybox-vless
    type: vless
    server: {ip}
    port: {e('PORT_VLESS')}
    uuid: {yq(e('UUID_VLESS'))}
    udp: true
    network: tcp
    flow: xtls-rprx-vision
    tls: true
    servername: {e('REALITY_SNI')}
    client-fingerprint: chrome
    reality-opts:
      public-key: {yq(e('REALITY_PUB'))}
      short-id: {yq(e('SHORT_ID'))}
  - name: mybox-vmess
    type: vmess
    server: {ip}
    port: {e('PORT_VMESS')}
    uuid: {yq(e('UUID_VMESS'))}
    alterId: 0
    cipher: auto
    udp: true
    network: ws
    ws-opts:
      path: {yq(e('VMESS_PATH'))}
      headers:
        Host: {yq(e('CERT_CN'))}
  - name: mybox-anytls
    type: anytls
    server: {ip}
    port: {e('PORT_ANYTLS')}
    password: {yq(e('PASS_ANYTLS'))}
    sni: {e('CERT_CN')}
    skip-cert-verify: true
  - name: mybox-hy2
    type: hysteria2
    server: {ip}
    port: {e('PORT_HY2')}
    password: {yq(e('PASS_HY2'))}
    sni: {e('CERT_CN')}
    skip-cert-verify: true
  - name: mybox-tuic
    type: tuic
    server: {ip}
    port: {e('PORT_TUIC')}
    uuid: {yq(e('UUID_TUIC'))}
    password: {yq(e('PASS_TUIC'))}
    version: 5
    alpn: [h3]
    congestion-controller: bbr
    sni: {e('CERT_CN')}
    skip-cert-verify: true

proxy-groups:
  - name: PROXY
    type: select
    proxies: [mybox-vless, mybox-vmess, mybox-anytls, mybox-hy2, mybox-tuic, DIRECT]

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
"""
open(os.path.join(outdir, "clash.yaml"), "w").write(clash)
print("client files:", os.path.join(outdir, "links.txt"), os.path.join(outdir, "clash.yaml"))
PY
  chmod 600 "$outdir/links.txt" "$outdir/clash.yaml"
}

write_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=mybox (sing-box, personal clean build)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

open_firewall() {
  if have ufw && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow "$PORT_VLESS/tcp"  >/dev/null
    ufw allow "$PORT_VMESS/tcp"  >/dev/null
    ufw allow "$PORT_ANYTLS/tcp" >/dev/null
    ufw allow "$PORT_HY2/udp"     >/dev/null
    ufw allow "$PORT_TUIC/udp"   >/dev/null
    log "UFW 已放行五协议端口"
  else
    warn "UFW 未启用或不存在，未改防火墙；云厂商安全组/防火墙请手动放行："
    warn "  TCP $PORT_VLESS $PORT_VMESS $PORT_ANYTLS ；UDP $PORT_HY2 $PORT_TUIC"
  fi
}

do_install() {
  need_root install
  install_deps
  mkdir -p "$DIR" "$DIR/backup"
  install_core
  load_or_create_creds
  make_cert
  if [ -f "$CONF" ]; then
    cp -a "$CONF" "$DIR/backup/config-$(date +%Y%m%d-%H%M%S).json"
    log "旧配置已备份到 $DIR/backup/"
  fi
  export PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC REALITY_SNI CERT_CN CERT_FILE KEY_FILE
  write_config
  if ! "$BIN" check -c "$CONF"; then
    die "新配置未通过 sing-box check，已保留备份，服务未重启"
  fi
  log "配置校验通过"
  write_unit
  systemctl enable --now mybox >/dev/null 2>&1 || systemctl restart mybox
  open_firewall
  local ip; ip="$(detect_ip)"
  if [ -n "$ip" ]; then
    export CERT_CN
    write_client_files "$ip"
  else
    warn "未能自动探测公网 IP，跳过链接生成；用 SERVER_IP=x.x.x.x 重新运行 install 补生成"
  fi
  systemctl --no-pager --lines=0 status mybox | head -n 5 || true
  log "完成。链接与 Clash 配置在 $DIR/client/（600），凭据总钥匙在 $CREDS（600）"
}

do_uninstall() {
  need_root uninstall
  systemctl disable --now mybox 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  rm -f "$BIN"
  if have ufw; then
    ufw delete allow "$PORT_VLESS/tcp"  >/dev/null 2>&1 || true
    ufw delete allow "$PORT_VMESS/tcp"  >/dev/null 2>&1 || true
    ufw delete allow "$PORT_ANYTLS/tcp" >/dev/null 2>&1 || true
    ufw delete allow "$PORT_HY2/udp"     >/dev/null 2>&1 || true
    ufw delete allow "$PORT_TUIC/udp"   >/dev/null 2>&1 || true
  fi
  rm -rf "$DIR"
  log "已卸载：服务、二进制、$DIR 已删除（如另有备份请自行清理）"
}

do_print_config() {
  # 免 root 预览：用临时凭据生成配置打到标准输出，不写盘、不碰系统
  UUID_VLESS="11111111-1111-1111-1111-111111111111"
  UUID_VMESS="22222222-2222-2222-2222-222222222222"
  UUID_TUIC="33333333-3333-3333-3333-333333333333"
  PASS_ANYTLS="preview-anytls-pass" PASS_HY2="preview-hy2-pass" PASS_TUIC="preview-tuic-pass"
  REALITY_PRIV="preview-reality-private-key" SHORT_ID="0123abcd" VMESS_PATH="/preview-vm"
  # 若本机已有 sing-box 二进制（可用 SB_BIN 指定），用真密钥生成预览，方便直接 sing-box check
  local cand
  for cand in "${SB_BIN:-}" "$BIN"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
      REALITY_PRIV="$("$cand" generate reality-keypair | awk '/PrivateKey/{print $2}')"
      break
    fi
  done
  export UUID_VLESS UUID_VMESS UUID_TUIC PASS_ANYTLS PASS_HY2 PASS_TUIC REALITY_PRIV SHORT_ID VMESS_PATH
  export PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC REALITY_SNI
  local tmp; tmp="$(mktemp)"
  CONF="$tmp" write_config >/dev/null
  cat "$tmp"; rm -f "$tmp"
}

do_show_links() {
  [ -f "$CREDS" ] || die "尚未安装（$CREDS 不存在）"
  set -a; . "$CREDS"; set +a
  export CERT_CN
  local ip; ip="$(detect_ip)"
  [ -n "$ip" ] || die "探测不到公网 IP，请用 SERVER_IP=x.x.x.x 指定"
  export CERT_CN
  write_client_files "$ip" >/dev/null
  cat "$DIR/client/links.txt"
}

case "${1:-}" in
  install)      do_install ;;
  uninstall)    do_uninstall ;;
  print-config) do_print_config ;;
  show-links)   need_root show-links; do_show_links ;;
  status)       systemctl --no-pager status mybox | head -n 12; "$BIN" check -c "$CONF" && echo "config: OK" ;;
  *) echo "用法： $0 {install|uninstall|print-config|show-links|status}"; exit 1 ;;
esac
