# 甬哥 sing-box 一键脚本拆解报告

对象：yonggekkk/sing-box-yg 的 sb.sh（与 o-vip 上 /etc/s-box 落地结构一致）
规模：4468 行 / 约 149 KB / 单文件 bash
日期：2026-10-23

## 一、它实际由什么组成

| 部分 | 规模/证据 | 说明 |
|---|---|---|
| 五协议服务端配置生成 | 函数 inssbjsonser 约 457 行 | 真正的核心：生成 /etc/s-box/sb.json（VLESS-REALITY、VMess、Hysteria2、TUIC、AnyTLS） |
| 内核安装 | inssb / sbservice | 下载 sing-box 内核到 /etc/s-box、注册 systemd 服务 |
| 客户端/订阅生成 | sball + clall 约 1200 行 | 生成各客户端链接、Clash/Sing-box 配置、聚合订阅文件（jhdy 等） |
| Argo 隧道 | 提及 212 处，cloudflared 相关函数约 300 行 | 固定/临时隧道、域名接入，属于附加功能 |
| WARP 出站 | 提及 89 处 + wgcf 注册函数 | 注册 WARP 账号、改出站分流 |
| GitLab 订阅托管 | gitlabsub 等函数 | 把订阅推送到 GitLab，需要 token，仓库文件列表中可见 gitlabtoken.txt |
| TG 通知 | tgnotice / sbtg.sh | 把节点信息推给 Telegram 机器人 |
| 运维菜单 | 主菜单 0-16 项 | 改端口、改 UUID、改分流、端口转发、重启、升级脚本/内核、定时任务等 |
| 自更新/快捷命令 | lnsb / upsbyg、cronsb | 把脚本本身塞进系统并可自更新，另有定时重启类 cron |
| 系统改动 | iptables 提及 27 处、crontab 39 处 | 开端口、写定时任务、装依赖、二维码生成等 |

## 二、信任面（脚本会联系的外部服务）

下载/请求动作约 61 处（curl/wget）。域名去重后包括：
github.com、raw.githubusercontent.com、gitlab.com、cdn.jsdelivr.net、data.jsdelivr.com、
www.cloudflare.com、api.cloudflareclient.com、ip.fm、myip.ipip.net、
api.telegram.org、mirrors.aliyun.com、ygkkk.blogspot.com（作者博客）等。

## 三、在 o-vip 上的落地痕迹（与今日盘点相互印证）

- /etc/s-box/ 下几十个文件：sb.json / sb10.json / sb11.json、sing-box 内核、cert.pem、private.key、public.key、SHA256.txt，以及大量 *_client*.txt、clmi.yaml、jhdy.txt、各类 .log 与 token 文件
- /root 下有 sbyg_update、warp_update、geoip.db、geosite.db
- /usr/local/bin 有 singbox-healthcheck
- 五个协议共用同一个 UUID/密码（OR.yaml 中 VIP 五节点一致），一个泄露等于全协议泄露
- 对外开放 5 个协议端口 + 后加的中转 40137，与脚本默认布局一致

## 四、个人纯净版可保留/应剔除

保留（约 250-350 行即可实现）：
- 固定版本 sing-box 内核 + SHA256 校验（不追 latest）
- 五协议入站，各协议独立 UUID/密码（不再共用一个）
- 自签证书生成、systemd 单元、UFW 只放行所选端口
- 配置生成后先 sing-box check 校验、备份旧配置再重启
- 输出分享链接 + 一份 Clash yaml 到指定文件，幂等可重跑，带 uninstall

剔除：
- Argo 隧道、WARP 注册与分流菜单、GitLab 订阅托管、TG 推送
- 聚合订阅、客户端全家桶生成（约 1200 行）
- 自更新、快捷命令、定时重启 cron、端口转发与各种改来改去的菜单
- 一切把 token/密钥明文散落在配置目录的设计

## 五、结论

能做，且不难：这台机的服务端配置结构今天已在中转改造中实际动过并验证可用，
纯净版等于把 4468 行砍到只剩装内核 + 写配置 + 起服务三步。保持原端口与协议不变，
现有 Clash 订阅可无缝继续用；若同时更换为独立凭据，则需要同步更新订阅文件。
