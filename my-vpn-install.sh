#!/usr/bin/env bash
# =============================================================================
# My-vpn —— 个人纯净版 sing-box 五协议安装脚本
#
# 只做三件事：装内核、写配置、起服务。
# 没有菜单、没有订阅托管、没有 Argo/WARP/TG 推送、没有自更新、没有定时重启。
#
# 支持环境（通用模板）：x86_64 / arm64 + systemd 的
#   Debian 11+ / Ubuntu 20.04+ / RHEL 8+ / Rocky / AlmaLinux / CentOS Stream
# 依赖自动按 apt / dnf / yum 安装；本机防火墙支持 UFW 与 firewalld，
# 云厂商安全组需自行放行（脚本会打印要放行的端口）。
#
# 协议（凭据每个协议独立生成；端口首次安装随机生成并持久化，之后保持不变）：
#   VLESS-REALITY (TCP) / VMess-WS (TCP) / AnyTLS (TCP)
#   Hysteria2 (UDP)     / TUIC (UDP)
#
# 用法：
#   sudo bash my-vpn-install.sh install      安装或更新（可重复运行，凭据/端口不重置）
#   sudo bash my-vpn-install.sh uninstall    普通卸载：服务、配置、凭据、内核（保留面板/脚本）
#   sudo bash my-vpn-install.sh purge        完全卸载：以上全删 + 面板、脚本、备份、BBR 配置
#        bash my-vpn-install.sh print-config 只打印将要生成的 config.json（免 root 预览）
#        bash my-vpn-install.sh show-links   根据已保存凭据重新打印分享链接
#
# 可用环境变量覆盖（一般不用改）：
#   SB_VERSION   sing-box 版本（默认锁定 1.14.4，不追 latest）
#   SERVER_IP    服务器公网 IP（默认自动探测，探测失败时必须手动指定）
#   PORT_VLESS / PORT_VMESS / PORT_ANYTLS / PORT_HY2 / PORT_TUIC
#   REALITY_SNI  默认 apple.com ；CERT_CN 自签证书 CN，默认 www.bing.com
#
# 凭据保存在 /etc/my-vpn/credentials.env（权限 600），这是全套节点的总钥匙，
# 泄露等于五协议全泄露，请按私钥级别保管，不要外发。
# =============================================================================
set -euo pipefail

SB_VERSION="${SB_VERSION:-1.14.4}"
DIR="/etc/my-vpn"
CONF="$DIR/config.json"
CREDS="$DIR/credentials.env"
CERT_FILE="${CERT_FILE:-$DIR/cert.pem}"
KEY_FILE="${KEY_FILE:-$DIR/private.key}"
BIN="/usr/local/bin/sing-box"
UNIT="/etc/systemd/system/my-vpn.service"

# 端口不在这里写死：resolve_ports 按 环境变量 > ports.env > 现有 config.json > 随机 解析
PORT_VLESS="${PORT_VLESS:-}"
PORT_VMESS="${PORT_VMESS:-}"
PORT_ANYTLS="${PORT_ANYTLS:-}"
PORT_HY2="${PORT_HY2:-}"
PORT_TUIC="${PORT_TUIC:-}"
PORTS_FILE="$DIR/ports.env"
REALITY_SNI="${REALITY_SNI:-apple.com}"
CERT_CN="${CERT_CN:-www.bing.com}"

log()  { printf '\033[32m[my-vpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[my-vpn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[my-vpn] 错误：\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 运行（sudo bash $0 $1）"; }
have() { command -v "$1" >/dev/null 2>&1; }

arch_map() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

pkg_mgr() {
  if have apt-get && [ -f /etc/debian_version ]; then echo apt
  elif have dnf; then echo dnf
  elif have yum; then echo yum
  else echo none; fi
}

preflight() { # 通用环境检查：架构 + systemd（服务托管方式），不满足直接说明原因
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "不支持的架构：$(uname -m)（仅支持 x86_64 / arm64）" ;;
  esac
  { have systemctl && [ -d /run/systemd/system ]; } \
    || die "未检测到 systemd：本脚本用 systemd 托管服务，请在带 systemd 的系统（Debian/Ubuntu/RHEL 系主流发行版）上运行"
}

install_deps() {
  local missing=()
  for c in curl tar openssl python3 sha256sum ss free; do have "$c" || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] && return 0
  local mgr; mgr="$(pkg_mgr)"
  log "安装缺失依赖：${missing[*]}（包管理器：$mgr）"
  case "$mgr" in
    apt)
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        curl tar openssl python3 ca-certificates iproute2 procps coreutils >/dev/null ;;
    dnf) dnf install -y -q curl tar openssl python3 ca-certificates iproute procps-ng coreutils >/dev/null ;;
    yum) yum install -y -q curl tar openssl python3 ca-certificates iproute procps-ng coreutils >/dev/null ;;
    *) die "缺少依赖 ${missing[*]}，且未识别到 apt/dnf/yum，请手动安装这些命令后重试：curl tar openssl python3 sha256sum ss free" ;;
  esac
  local still=()
  for c in curl tar openssl python3 sha256sum ss free; do have "$c" || still+=("$c"); done
  [ "${#still[@]}" -eq 0 ] || die "依赖仍缺失：${still[*]}，请手动安装后重试"
}

gen_uuid() {
  if [ -x "$BIN" ]; then "$BIN" generate uuid;
  elif [ -f /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid;
  else python3 -c 'import uuid;print(uuid.uuid4())'; fi
}

# ---------- 端口解析：环境变量 > ports.env > 现有 config.json > 随机（仅首次安装） ----------
cfg_port() { # $1=协议类型 -> 从现有 config.json 读 listen_port
  [ -f "$CONF" ] || return 0
  python3 - "$CONF" "$1" 2>/dev/null <<'PY' || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    for ib in cfg.get("inbounds", []):
        if ib.get("type") == sys.argv[2]:
            print(ib.get("listen_port", "")); break
except Exception:
    pass
PY
}

file_port() { # $1=变量名 -> 从 ports.env 读
  [ -f "$PORTS_FILE" ] || return 0
  sed -n "s/^$1='\([0-9][0-9]*\)'.*/\1/p" "$PORTS_FILE" | tail -n 1
}

rand_port() { # 20000-60000 内随机、未被本机监听、未与已定端口重复
  local p i
  for i in $(seq 1 60); do
    p=$(( (RANDOM * 32768 + RANDOM) % 40001 + 20000 ))
    case " $USED_PORTS " in *" $p "*) continue ;; esac
    if have ss && ss -tuln 2>/dev/null | grep -q ":$p[[:space:]]"; then continue; fi
    echo "$p"; return 0
  done
  return 1
}

resolve_ports() { # $1: install=缺失时随机生成；clean=缺失时回落旧固定端口（预览/卸载用）
  local mode="${1:-install}"
  PORT_VLESS="${PORT_VLESS:-$(file_port PORT_VLESS)}"
  PORT_VMESS="${PORT_VMESS:-$(file_port PORT_VMESS)}"
  PORT_ANYTLS="${PORT_ANYTLS:-$(file_port PORT_ANYTLS)}"
  PORT_HY2="${PORT_HY2:-$(file_port PORT_HY2)}"
  PORT_TUIC="${PORT_TUIC:-$(file_port PORT_TUIC)}"
  [ -n "$PORT_VLESS" ]  || PORT_VLESS="$(cfg_port vless)"
  [ -n "$PORT_VMESS" ]  || PORT_VMESS="$(cfg_port vmess)"
  [ -n "$PORT_ANYTLS" ] || PORT_ANYTLS="$(cfg_port anytls)"
  [ -n "$PORT_HY2" ]     || PORT_HY2="$(cfg_port hysteria2)"
  [ -n "$PORT_TUIC" ]    || PORT_TUIC="$(cfg_port tuic)"
  if [ "$mode" = "install" ]; then
    USED_PORTS="22 $PORT_VLESS $PORT_VMESS $PORT_ANYTLS $PORT_HY2 $PORT_TUIC"
    local var
    for var in PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC; do
      if [ -z "${!var}" ]; then
        printf -v "$var" '%s' "$(rand_port)"
        USED_PORTS="$USED_PORTS ${!var}"
        log "首次安装：$var 随机生成 ${!var}"
      fi
    done
    { [ -n "$PORT_VLESS" ] && [ -n "$PORT_VMESS" ] && [ -n "$PORT_ANYTLS" ] \
      && [ -n "$PORT_HY2" ] && [ -n "$PORT_TUIC" ]; } || die "端口解析失败"
  else
    PORT_VLESS="${PORT_VLESS:-40136}"; PORT_VMESS="${PORT_VMESS:-2082}"
    PORT_ANYTLS="${PORT_ANYTLS:-20917}"; PORT_HY2="${PORT_HY2:-41413}"
    PORT_TUIC="${PORT_TUIC:-59899}"
  fi
  export PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC
}

save_ports() {
  umask 077
  {
    printf "PORT_VLESS='%s'\n"  "$PORT_VLESS"
    printf "PORT_VMESS='%s'\n"  "$PORT_VMESS"
    printf "PORT_ANYTLS='%s'\n" "$PORT_ANYTLS"
    printf "PORT_HY2='%s'\n"    "$PORT_HY2"
    printf "PORT_TUIC='%s'\n"   "$PORT_TUIC"
  } > "$PORTS_FILE"
  chmod 600 "$PORTS_FILE"
}

# ---------- 凭据：首次生成并落盘（600），之后重跑直接复用 ----------
load_or_create_creds() {
  if [ -f "$CREDS" ]; then
    # shellcheck disable=SC1090
    set -a; . "$CREDS"; set +a
    log "复用已有凭据（$CREDS）"
    # 凭据不完整时绝不能带着空值往下写配置（会生成一条“能通过 check、但谁也连不上”的坏配置），
    # 直接停下来说明原因，让人备份后删文件重装，而不是悄悄生成坏节点
    local missing_creds="" k
    for k in UUID_VLESS UUID_VMESS UUID_TUIC PASS_ANYTLS PASS_HY2 PASS_TUIC REALITY_PRIV REALITY_PUB SHORT_ID VMESS_PATH; do
      [ -n "${!k:-}" ] || missing_creds="$missing_creds $k"
    done
    if [ -n "$missing_creds" ]; then
      die "凭据文件不完整，缺：$missing_creds。请先备份 $CREDS，再删除它后重跑 install 重新生成全套（注意：五条客户端链接会全部变）"
    fi
    if [ -z "${PASS_OBFS:-}" ]; then
      PASS_OBFS="$(openssl rand -base64 18 | tr -d '\n')"
      printf "PASS_OBFS='%s'\n" "$PASS_OBFS" >> "$CREDS"
      chmod 600 "$CREDS"
      export PASS_OBFS
      log "已补生成 Hysteria2 混淆密码（PASS_OBFS）并追加到凭据文件"
    fi
    return 0
  fi
  UUID_VLESS="$(gen_uuid)"
  UUID_VMESS="$(gen_uuid)"
  UUID_TUIC="$(gen_uuid)"
  PASS_ANYTLS="$(openssl rand -base64 18 | tr -d '\n')"
  PASS_HY2="$(openssl rand -base64 18 | tr -d '\n')"
  PASS_OBFS="$(openssl rand -base64 18 | tr -d '\n')"
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
    printf "PASS_OBFS='%s'\n"     "$PASS_OBFS"
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
  digest="$(curl -fsSL --retry 2 --max-time 20 "$api" | python3 -c '
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
       "certificate_path": os.environ.get("CERT_FILE", "/etc/my-vpn/cert.pem"),
       "key_path": os.environ.get("KEY_FILE", "/etc/my-vpn/private.key")}
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
     "users": [{"password": e("PASS_HY2")}],
     "obfs": {"type": "salamander", "password": e("PASS_OBFS")},
     "tls": {**tls, "alpn": ["h3"]}},
    {"type": "tuic", "tag": "tuic-in", "listen": "::",
     "listen_port": int(e("PORT_TUIC")),
     "users": [{"uuid": e("UUID_TUIC"), "password": e("PASS_TUIC")}],
     "congestion_control": "bbr",
     "tls": {**tls, "alpn": ["h3"]}},
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"default_domain_resolver": "local", "final": "direct"},
}
# 全协议嗅探：与勇哥版对齐，域名分流类客户端不再因无嗅探而走偏。
for _ib in cfg["inbounds"]:
    _ib["sniff"] = True
    _ib["sniff_override_destination"] = True
# VMess TLS 开关：默认关（保持现有纯 WS 行为，老链接不变）；VMESS_TLS=1 时
# 用同一张自签证书做 WS+TLS，客户端链接与 Clash 配置同步带 tls/sni。
if os.environ.get("VMESS_TLS") in ("1", "true", "yes"):
    for _ib in cfg["inbounds"]:
        if _ib["type"] == "vmess":
            _vmess_tls = dict(tls)
            _vmess_tls["server_name"] = os.environ.get("CERT_CN", "www.bing.com")
            _ib["tls"] = _vmess_tls
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
print("config written:", sys.argv[1])
PY
}

detect_ip() {
  if [ -n "${SERVER_IP:-}" ]; then echo "$SERVER_IP"; return 0; fi
  local ip=""
  ip="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -fsS --max-time 6 https://ifconfig.me/ip 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -fsS --max-time 6 https://ip.sb 2>/dev/null || true)"
  printf '%s' "$ip" | tr -d '[:space:]'
}

# ---------- 客户端产物：链接 + 一份 Clash 配置，只写到本机目录 ----------
write_client_files() {
  local ip="$1" outdir="$DIR/client"
  mkdir -p "$outdir"
  # 客户端生成靠环境变量传参，这里统一导出，避免 show-links 路径下端口为 None
  export PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC REALITY_SNI CERT_CN VMESS_TLS
  export UUID_VLESS UUID_VMESS UUID_TUIC PASS_ANYTLS PASS_HY2 PASS_TUIC PASS_OBFS
  export REALITY_PUB SHORT_ID VMESS_PATH
  SERVER_IP_OUT="$ip" python3 - "$outdir" <<'PY'
import base64, json, os, sys
outdir = sys.argv[1]
e = os.environ.get
ip = e("SERVER_IP_OUT")
def q(s):  # URL 里密码可能含 +/=，做百分号编码
    from urllib.parse import quote
    return quote(s, safe="")
vmess_obj = {"v": "2", "ps": "my-vpn-vmess", "add": ip, "port": str(e("PORT_VMESS")),
             "id": e("UUID_VMESS"), "aid": "0", "net": "ws",
             "path": e("VMESS_PATH"), "host": e("CERT_CN"), "tls": ""}
if e("VMESS_TLS") in ("1", "true", "yes"):
    vmess_obj["tls"] = "tls"
    vmess_obj["sni"] = e("CERT_CN")
# Hy2 混淆密码缺失时不崩：老安装（加混淆之前）服务端也没有混淆，链接里就
# 不带 obfs 参数，与服务端保持一致；服务端要求混淆但凭据缺失的情况由
# do_show_links 提前拦下，不会走到这里生成一条对不上的链接。
_hy2_obfs = e("PASS_OBFS")
hy2_obfs_q = f"&obfs=salamander&obfs-password={q(_hy2_obfs)}" if _hy2_obfs else ""
links = [
 f"vless://{e('UUID_VLESS')}@{ip}:{e('PORT_VLESS')}?encryption=none&flow=xtls-rprx-vision"
 f"&security=reality&sni={e('REALITY_SNI')}&fp=chrome&pbk={e('REALITY_PUB')}"
 f"&sid={e('SHORT_ID')}&type=tcp&headerType=none#my-vpn-vless",
 "vmess://" + base64.b64encode(json.dumps(vmess_obj).encode()).decode(),
 f"anytls://{q(e('PASS_ANYTLS'))}@{ip}:{e('PORT_ANYTLS')}/?insecure=1&sni={e('CERT_CN')}#my-vpn-anytls",
 f"hysteria2://{q(e('PASS_HY2'))}@{ip}:{e('PORT_HY2')}/?insecure=1&sni={e('CERT_CN')}"
 f"&alpn=h3{hy2_obfs_q}#my-vpn-hy2",
 f"tuic://{e('UUID_TUIC')}:{q(e('PASS_TUIC'))}@{ip}:{e('PORT_TUIC')}"
 f"?congestion_control=bbr&alpn=h3&sni={e('CERT_CN')}&allow_insecure=1#my-vpn-tuic",
]
open(os.path.join(outdir, "links.txt"), "w").write("\n".join(links) + "\n")

def yq(s): return "'" + str(s).replace("'", "''") + "'"
vmess_tls_yaml = f"    tls: true\n    servername: {e('CERT_CN')}\n" if e("VMESS_TLS") in ("1", "true", "yes") else ""
hy2_obfs_yaml = f"    obfs: salamander\n    obfs-password: {yq(e('PASS_OBFS'))}\n" if e("PASS_OBFS") else ""
clash = f"""mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

proxies:
  - name: my-vpn-vless
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
  - name: my-vpn-vmess
    type: vmess
    server: {ip}
    port: {e('PORT_VMESS')}
    uuid: {yq(e('UUID_VMESS'))}
    alterId: 0
    cipher: auto
    udp: true
    network: ws
{vmess_tls_yaml}    ws-opts:
      path: {yq(e('VMESS_PATH'))}
      headers:
        Host: {yq(e('CERT_CN'))}
  - name: my-vpn-anytls
    type: anytls
    server: {ip}
    port: {e('PORT_ANYTLS')}
    password: {yq(e('PASS_ANYTLS'))}
    sni: {e('CERT_CN')}
    skip-cert-verify: true
  - name: my-vpn-hy2
    type: hysteria2
    server: {ip}
    port: {e('PORT_HY2')}
    password: {yq(e('PASS_HY2'))}
{hy2_obfs_yaml}    alpn: [h3]
    sni: {e('CERT_CN')}
    skip-cert-verify: true
  - name: my-vpn-tuic
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
    proxies: [my-vpn-vless, my-vpn-vmess, my-vpn-anytls, my-vpn-hy2, my-vpn-tuic, DIRECT]

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
Description=my-vpn (sing-box, personal clean build)
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
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    local spec
    for spec in "$PORT_VLESS/tcp" "$PORT_VMESS/tcp" "$PORT_ANYTLS/tcp" "$PORT_HY2/udp" "$PORT_TUIC/udp"; do
      firewall-cmd --permanent --add-port="$spec" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "firewalld 已放行五协议端口"
  else
    warn "UFW/firewalld 均未启用，未改本机防火墙；云厂商安全组请手动放行："
    warn "  TCP $PORT_VLESS $PORT_VMESS $PORT_ANYTLS ；UDP $PORT_HY2 $PORT_TUIC"
  fi
}

do_install() {
  need_root install
  preflight
  install_deps
  mkdir -p "$DIR" "$DIR/backup"
  resolve_ports install
  install_core
  load_or_create_creds
  save_ports
  make_cert
  if [ -f "$CONF" ]; then
    cp -a "$CONF" "$DIR/backup/config-$(date +%Y%m%d-%H%M%S).json"
    log "旧配置已备份到 $DIR/backup/"
  fi
  export PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC REALITY_SNI CERT_CN CERT_FILE KEY_FILE VMESS_TLS
  write_config
  if ! "$BIN" check -c "$CONF"; then
    die "新配置未通过 sing-box check，已保留备份，服务未重启"
  fi
  log "配置校验通过"
  write_unit
  systemctl enable --now my-vpn >/dev/null 2>&1 || systemctl restart my-vpn
  open_firewall
  # 装后核验：以前这里只打印“完成”，服务起没起来、端口有没有在监听都不查，
  # 这次装完当场验，起不来直接报错停下，不留一个“看着装完了、其实连不上”的状态
  if [ "$(systemctl is-active my-vpn 2>/dev/null)" != "active" ]; then
    warn "my-vpn 服务未进入 active，最近日志："
    journalctl -u my-vpn --no-pager -n 20 2>/dev/null || true
    die "安装未完成：my-vpn 服务未正常运行，旧配置备份在 $DIR/backup/，先看日志再重装"
  fi
  local missing_ports="" pp
  for pp in "$PORT_VLESS" "$PORT_VMESS" "$PORT_ANYTLS"; do
    ss -tln 2>/dev/null | grep -q ":$pp[[:space:]]" || missing_ports="$missing_ports $pp(TCP)"
  done
  for pp in "$PORT_HY2" "$PORT_TUIC"; do
    ss -uln 2>/dev/null | grep -q ":$pp[[:space:]]" || missing_ports="$missing_ports $pp(UDP)"
  done
  if [ -n "$missing_ports" ]; then
    warn "服务在运行，但以下端口未在监听，客户端可能连不上：$missing_ports（先查防火墙与端口占用）"
  else
    log "服务运行中，五协议端口均已在监听"
  fi
  local ip; ip="$(detect_ip)"
  if [ -n "$ip" ]; then
    export CERT_CN
    write_client_files "$ip"
  else
    warn "未能自动探测公网 IP，跳过链接生成；用 SERVER_IP=x.x.x.x 重新运行 install 补生成"
  fi
  systemctl --no-pager --lines=0 status my-vpn | head -n 5 || true
  log "完成。链接与 Clash 配置在 $DIR/client/（600），凭据总钥匙在 $CREDS（600）"
}

close_firewall() {
  if have ufw; then
    ufw delete allow "$PORT_VLESS/tcp"  >/dev/null 2>&1 || true
    ufw delete allow "$PORT_VMESS/tcp"  >/dev/null 2>&1 || true
    ufw delete allow "$PORT_ANYTLS/tcp" >/dev/null 2>&1 || true
    ufw delete allow "$PORT_HY2/udp"     >/dev/null 2>&1 || true
    ufw delete allow "$PORT_TUIC/udp"   >/dev/null 2>&1 || true
  fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    local spec
    for spec in "$PORT_VLESS/tcp" "$PORT_VMESS/tcp" "$PORT_ANYTLS/tcp" "$PORT_HY2/udp" "$PORT_TUIC/udp"; do
      firewall-cmd --permanent --remove-port="$spec" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

do_uninstall() {
  need_root uninstall
  resolve_ports clean   # 先按 ports.env/config 读出实际端口，再删文件（保证 UFW 规则删对）
  systemctl disable --now my-vpn 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed my-vpn 2>/dev/null || true
  rm -f "$BIN" "$BIN.bak"
  close_firewall
  rm -rf "$DIR"
  log "已卸载：服务、内核、$DIR（配置/凭据/端口）已删除；面板命令与安装脚本保留，可随时重装"
}

do_purge() { # 完全卸载：连面板、脚本、备份、BBR 持久化一并清除
  need_root purge
  if [ "${1:-}" != "--yes" ] && [ -t 0 ]; then
    local ans
    printf '完全卸载将删除 my-vpn 的一切（服务/配置/凭据/内核/面板/脚本/备份/BBR 配置），不可恢复。输入 PURGE 确认：'
    read -r ans || exit 1
    [ "$ans" = "PURGE" ] || { log "已取消"; exit 0; }
  fi
  resolve_ports clean
  systemctl disable --now my-vpn 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed my-vpn 2>/dev/null || true
  rm -f "$BIN" "$BIN.bak" /usr/local/bin/my-vpn /root/my-vpn-install.sh /root/my-vpn-panel.sh
  close_firewall
  rm -rf "$DIR" /root/my-vpn-backups
  rm -f /etc/sysctl.d/99-my-vpn-bbr.conf /etc/modules-load.d/my-vpn-bbr.conf
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
  log "完全卸载完成：my-vpn 服务、配置、凭据、内核、面板命令、脚本、备份与 BBR 配置均已清除"
}

do_print_config() {
  resolve_ports clean
  # 免 root 预览：用临时凭据生成配置打到标准输出，不写盘、不碰系统
  UUID_VLESS="11111111-1111-1111-1111-111111111111"
  UUID_VMESS="22222222-2222-2222-2222-222222222222"
  UUID_TUIC="33333333-3333-3333-3333-333333333333"
  PASS_ANYTLS="preview-anytls-pass" PASS_HY2="preview-hy2-pass" PASS_TUIC="preview-tuic-pass"
  PASS_OBFS="preview-obfs-pass"
  REALITY_PRIV="preview-reality-private-key" SHORT_ID="0123abcd" VMESS_PATH="/preview-vm"
  # 若本机已有 sing-box 二进制（可用 SB_BIN 指定），用真密钥生成预览，方便直接 sing-box check
  local cand
  for cand in "${SB_BIN:-}" "$BIN"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
      REALITY_PRIV="$("$cand" generate reality-keypair | awk '/PrivateKey/{print $2}')"
      break
    fi
  done
  export UUID_VLESS UUID_VMESS UUID_TUIC PASS_ANYTLS PASS_HY2 PASS_TUIC PASS_OBFS REALITY_PRIV SHORT_ID VMESS_PATH
  export PORT_VLESS PORT_VMESS PORT_ANYTLS PORT_HY2 PORT_TUIC REALITY_SNI CERT_CN VMESS_TLS
  local tmp; tmp="$(mktemp)"
  CONF="$tmp" write_config >/dev/null
  cat "$tmp"; rm -f "$tmp"
}

do_show_links() {
  [ -f "$CREDS" ] || die "尚未安装（$CREDS 不存在）"
  set -a; . "$CREDS"; set +a
  resolve_ports clean
  # 混淆一致性检查：服务端配置要求 salamander、但凭据里没有 PASS_OBFS
  # （加混淆之前的老安装），此时只刷新链接会生成一条对不上的 Hy2 链接，
  # 必须重跑 install：它会补生成混淆密码并同步重写服务端配置和链接。
  if [ -z "${PASS_OBFS:-}" ] && [ -f "$CONF" ] && grep -q '"salamander"' "$CONF"; then
    die "凭据里没有 Hy2 混淆密码（PASS_OBFS），但服务端配置要求 salamander 混淆，链接与服务端对不上。请重跑 install（凭据复用，会补生成混淆密码并同步重写配置和链接），不要只刷新链接"
  fi
  export CERT_CN VMESS_TLS
  local ip; ip="$(detect_ip)"
  [ -n "$ip" ] || die "探测不到公网 IP，请用 SERVER_IP=x.x.x.x 指定"
  export CERT_CN
  write_client_files "$ip" >/dev/null
  cat "$DIR/client/links.txt"
}

case "${1:-}" in
  install)      do_install ;;
  uninstall)    do_uninstall ;;
  purge)        do_purge "${2:-}" ;;
  print-config) do_print_config ;;
  show-links)   need_root show-links; do_show_links ;;
  status)       systemctl --no-pager status my-vpn | head -n 12; "$BIN" check -c "$CONF" && echo "config: OK" ;;
  *) echo "用法： $0 {install|uninstall|purge|print-config|show-links|status}"; exit 1 ;;
esac
