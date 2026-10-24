# mybox —— 个人纯净版 sing-box 一键安装脚本

由甬哥 sing-box-yg（sb.sh，4468 行）拆解后重写的个人版本，约 440 行。
只做三件事：**装内核、写配置、起服务。**

拆解过程与取舍见 [TEARDOWN.md](TEARDOWN.md)。

## 快速开始

```bash
curl -fsSL -o mybox-install.sh https://raw.githubusercontent.com/Xudashu2023/mybox/main/mybox-install.sh
sudo bash mybox-install.sh install
```

或克隆仓库后本地运行 `sudo bash mybox-install.sh install`。

## 功能

- 五协议：VLESS-REALITY (TCP 40136) / VMess-WS (TCP 2082) / AnyTLS (TCP 20917) / Hysteria2 (UDP 41413) / TUIC (UDP 59899)，端口可用环境变量改
- 每个协议独立生成 UUID/密码（不再共用一个凭据）
- sing-box 内核锁定 1.14.3（不追 latest），下载后按 GitHub 官方发布摘要做 SHA256 校验，取不到摘要直接中止
- 配置写入前先 `sing-box check` 校验，并备份旧配置；重跑 install 不重置已有凭据
- 安装产物集中：二进制 `/usr/local/bin/sing-box`、配置目录 `/etc/mybox`、systemd 服务 `mybox`
- 凭据在 `/etc/mybox/credentials.env`（600），分享链接与 Clash 配置在 `/etc/mybox/client/`（600）

子命令：`install` / `uninstall` / `print-config`（免 root 预览配置）/ `show-links`

## 明确不做的事

没有菜单、没有 Argo 隧道、没有 WARP、没有 GitLab 订阅托管、没有 TG 推送、
没有聚合订阅全家桶、没有自更新、没有快捷命令、没有定时重启 cron。

## 许可

MIT，见 [LICENSE](LICENSE)。可自由使用、修改与分发。
本脚本与 sing-box 官方（SagerNet）及被拆解的原脚本作者无隶属关系；
在本机以 root 运行任何一键脚本前，请先通读脚本内容。

## 注意

- 自签证书 CN 默认 www.bing.com、REALITY SNI 默认 apple.com，均可用环境变量改
- 防火墙只处理 UFW（启用时放行五协议端口）；云厂商安全组需自行放行
- 服务端配置按 sing-box 1.14 格式生成（1.14 已移除 VMess 服务端 alter_id 字段）

## 面板（可选附加件）

`mybox-panel.sh` 是独立的交互面板，装上后在服务器输 `mybox` 调出：
彩色仪表盘（服务状态、五端口监听点、内存/磁盘条、Hy2 握手修复标记），
菜单含查看链接、终端二维码导入、全协议本机自测、服务管理、日志、
流量统计、系统信息、修改 IP/端口/SNI、一键开启内核原版 BBR+FQ 加速、
Sing-box 内核版本管理（更新到最新 / 指定版本切换 / 官方版本摘要校验 / 失败自动回滚）、
从 GitHub 更新脚本与面板、备份/恢复、卸载。

```bash
curl -fsSL -o /usr/local/bin/mybox https://raw.githubusercontent.com/Xudashu2023/mybox/main/mybox-panel.sh
chmod 755 /usr/local/bin/mybox
mybox
```

核心安装脚本本身依旧无菜单、无快捷命令；面板只是它的可选外壳，
所有装/改/卸都转调安装脚本的子命令，配置与凭据只有一份。
