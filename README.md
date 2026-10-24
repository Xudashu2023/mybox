# mybox —— 个人纯净版 sing-box 一键安装脚本

只做三件事：**装内核、写配置、起服务。**


## 快速开始

```bash
curl -fsSL -o mybox-install.sh https://raw.githubusercontent.com/Xudashu2023/mybox/main/mybox-install.sh
sudo bash mybox-install.sh install
```

或克隆仓库后本地运行 `sudo bash mybox-install.sh install`。

## 功能

- 五协议：VLESS-REALITY / VMess-WS / AnyTLS / Hysteria2 / TUIC
- 端口：首次安装在 20000-60000 随机生成、互不重复且避开已占用端口，写入 `/etc/mybox/ports.env` 持久化；重装自动复用不变更。已有旧版 config.json 的机器保持原端口。可用环境变量 `PORT_*` 或面板指定
- 每个协议独立生成 UUID/密码（不再共用一个凭据）
- sing-box 内核锁定 1.14.3（不追 latest），下载后按 GitHub 官方发布摘要做 SHA256 校验，取不到摘要直接中止
- 配置写入前先 `sing-box check` 校验，并备份旧配置；重跑 install 不重置已有凭据
- 安装产物集中：二进制 `/usr/local/bin/sing-box`、配置目录 `/etc/mybox`、systemd 服务 `mybox`
- 凭据在 `/etc/mybox/credentials.env`（600），分享链接与 Clash 配置在 `/etc/mybox/client/`（600）

子命令：`install` / `uninstall`（普通卸载）/ `purge`（完全卸载）/ `print-config`（免 root 预览配置）/ `show-links` / `status`

## 一键安装（本体 + 面板）

```bash
curl -fsSL https://raw.githubusercontent.com/Xudashu2023/mybox/main/install.sh -o /tmp/mybox-all.sh && sudo bash /tmp/mybox-all.sh
```

一条命令装齐本体与面板，装完输 `mybox` 进面板。出站经 WARP/透明代理的机器需带上真实 IP（否则自动探测到的是代理出口）：`sudo SERVER_IP=x.x.x.x bash /tmp/mybox-all.sh`。

## 许可

MIT，见 [LICENSE](LICENSE)。可自由使用、修改与分发。
本脚本与 sing-box 官方（SagerNet）无隶属关系；
在本机以 root 运行任何一键脚本前，请先通读脚本内容。

## 注意

- 自签证书 CN 默认 www.bing.com、REALITY SNI 默认 apple.com，均可用环境变量改
- 防火墙只处理 UFW（启用时放行五协议端口）；云厂商安全组需自行放行
- 服务端配置按 sing-box 1.14 格式生成（1.14 已移除 VMess 服务端 alter_id 字段）

## 面板（可选附加件）

`mybox-panel.sh` 是独立的交互面板，装上后在服务器输 `mybox` 调出：
深色高级感设计（MY BOX 渐变块字主标、卡片式状态/节点区、
两位数编号留白菜单、香槟金点缀），
菜单含查看链接、终端二维码导入、全协议本机自测、服务管理、日志、
流量统计、系统信息、修改 IP/端口/SNI、一键开启内核原版 BBR+FQ 加速、
Sing-box 内核版本管理（更新到最新 / 指定版本切换 / 官方版本摘要校验 / 失败自动回滚）、
节点测速（逐协议本机回连下载 15MB 测速）、从 GitHub 更新脚本与面板、备份/恢复、两档卸载（普通卸载 / 完全卸载 purge：连面板、脚本、备份、BBR 配置一并清除）。

```bash
curl -fsSL -o /usr/local/bin/mybox https://raw.githubusercontent.com/Xudashu2023/mybox/main/mybox-panel.sh
chmod 755 /usr/local/bin/mybox
mybox
```

核心安装脚本本身依旧无菜单、无快捷命令；面板只是它的可选外壳，
所有装/改/卸都转调安装脚本的子命令，配置与凭据只有一份。
个人开发测试，仅为测试所有。
