# 会话纪要 — OpenWrt × mynet_agent 集成与 192.168.0.2 升级

> 日期：2026-09-29 ~ 2026-09-30
> 范围：mynet_lua→mynet_openwrt 分析 · 执行器/安装架构归位 · LuCI/WebUI 对比 ·
> OpenWrt SDK 出 ipk · 生产 192.168.0.2 升级
> 原则：结论带证据；不写过程性「我改了口」；坑单独列。

---

## 1. 架构口径（先对齐，否则后面全偏）

### 1.1 仓库与 UI 归属

| | 是什么 | UI |
|---|---|---|
| `mynet_openwrt`（原 mynet_lua） | OpenWrt 平台适配层 + ipk 包源 | **LuCI** |
| `mynet_agent` | mynetd + mynet（执行器）+ gateway | 桌面 **WebUI**（embed） |

**OpenWrt 上 mynetd 不带 embed WebUI**（D-11）；界面归 LuCI。
WebUI 只监听回环 `127.0.0.1:8096`，不往路由器推。

### 1.2 安装包 vs 服务安装（全平台）

```text
安装包（ipk/deb/MSI…）  →  文件落地：二进制、LuCI、默认 init
mynet install           →  服务装配：env + 服务单元 + enable/start
```

- `mynet install` **不 copy 二进制**（与包管理打架）。缺文件则报「归 ipk」。
- OpenWrt：`mynet-agent` 装 `/usr/sbin/{mynet,mynetd}`；`mynet install` 写 env/procd/zone。
- 桌面同理：tarball/包放文件，install 只装服务。

### 1.3 执行器双实现（同面不同实现）

| | 桌面 | OpenWrt |
|---|---|---|
| mynetd | 同一套（可 embed WebUI） | 同一套（瘦，无 embed） |
| 执行器 | `exec mynet <argv>` | **`lua -e`**（`MYNET_EXECUTOR=lua`） |
| L6 路由唯一写入者 | `mynet apply` | 同左（Lua shell 调用） |

- `commands.Executor` 可注入；OpenWrt 走 `executor_lua.go`。
- procd 管 gnb 生命周期（E-1）；Lua **不再 spawn/kill**，只委托 `/etc/init.d/mynet`。
- 双驱动：`VPN_TYPE=gnb|wireguard`（`openwrt_mynet.init` 分支）；wg 走内核接口，无常驻进程。

### 1.4 mynet_openwrt 里有什么 / 没什么

| 有 | 无 |
|---|---|
| LuCI 壳、scripts、ipk Makefile | **gnb 源码** |
| `gnb_installer.lua`（下载预编译） | gnb 补丁 |

gnb 补丁在 `mynet_gnb/packages/1.6.8-c411f14ee647/`（p1-hot-restart-v2 + **p2-route-proxy**）。
升级时 **勿覆盖** 现网 `driver/gnb/bin/gnb`，除非换成 packages 编出的补丁版（p2 是 proxy 能力）。

---

## 2. 本轮实现（代码落点）

| 能力 | 位置 |
|---|---|
| E-4 结果→WS | `cmd/mynetd/localresult.go` + `api.OnResult` |
| lua -e 执行器 | `cmd/mynetd/executor_lua.go`（argv→lua，`MYNET_ARGV`） |
| procd 双驱动 init | `mynet/units/openwrt_mynet{,d}.init` |
| 服务安装（无 copy） | `mynet/cmd_install_openwrt.go` / `cmd_install.go` / `cmd_install_win.go` |
| network/zone | `setupOpenWrtNetworkZone`（优先 `firewall.mynet install`） |
| wg 投影 | `writeWgProjection`；conf 对齐 `/etc/wireguard/<if>.conf` |
| localapi B2 | proxy store **注入**，不 import `shared/config` |
| UX U1 | `util.friendly_api_error()`（401→「云端未登录…」） |
| UX U5/U7 | Stop/Restart confirm；aria-label 唯一 |
| UX U3/U4/U6 | WebUI 8s 快照轮询 / 30–60s 超时 / 错误区 |
| CI OpenWrt SDK | `.github/workflows/build_openwrt.yml`（ipk 矩阵） |
| 跨仓 checkout | `secrets.GH_PAT` → `mynet-club/mynet_openwrt-V2` |

---

## 3. 192.168.0.2 升级记录

### 3.1 基线 → 目标

| | 升级前 | 升级后 |
|---|---|---|
| 系统 | ImmortalWrt 24.10.0 x86_64 | 同 |
| 包 | luci-app-mynet **2.1.6**（纯 Lua） | luci-app-mynet + **mynet-agent 2.1.8** |
| 服务 | 旧 init，Lua 管 gnb | procd（mynetd + gnb 实例） |
| 心跳 | cron `*/5 mynet-heartbeat` | **mynetd**（cron 已摘） |
| proxy | live（nft ~3007 行） | 已恢复（nft set 17815 + fwmark 31800） |

### 3.2 产物

GitHub Actions `build-openwrt-sdk`（官方 SDK 24.10）：

```text
mynet-agent_2.1.8-r1_x86_64.ipk      # mynetd + mynet（含 proxy）
luci-app-mynet_2.1.8-r1_all.ipk
```

矩阵：amd64 / arm64 / mipsel。artifact **只收这两个包**（不带 feeds 全量）。

### 3.3 验证摘录（升级后）

```text
mynetd  MYNET_EXECUTOR=lua MYNET_HOME=/etc/mynet MYNET_GATEWAYS=…
gnb     procd instance pid=24661  gnb_tun_16 UP
proxy   table inet mynet_proxy + ip rule 31800 fwmark 0xc8
routes  25 条（17 条隧道路由自 route.conf 恢复）
ping    10.182.236.180 OK · 10.147.97.76 OK
https   api.mynet.club/up 200
cron    mynet-heartbeat 已移除
```

备份：`/root/mynet-backup-20260930-091117/`（mynet-home、nft、LuCI、crontab、opkg）。

---

## 4. 坑（独立列出）

| # | 坑 | 教训 |
|---|---|---|
| 1 | `nid(nil)`→`"0"`，`stop_gnb` 假成功 | Lua 封装必须回退 `cfg.get_node_id()`；假成功比报错更难查 |
| 2 | pidfile 与真实 gnb 失步 | stop 要 pidfile+cmdline 双验，必要时按 conf 路径扫 |
| 3 | `fw4 reload` 在 QEMU 可挂死 | 同步 reload 不得阻塞 stop/HTTP；能不 reload 就不 reload |
| 4 | `$(basename)` 在 Makefile 被 GNU make 吃掉 | 用 `sed` 截路径；`$()` 是 make 函数名 |
| 5 | `-s -w` 剥符号后 `go tool nm` 失效 | CI 校验用 `strings \| grep mynet.ApplyProxy` |
| 6 | Actions `GITHUB_TOKEN` 不能跨私有仓 | 用账号 token 写入 `secrets.GH_PAT` |
| 7 | `firewall.mynet install` 要 `MYNET_HOME` | 调脚本必须带 env |
| 8 | `mynetd.init` 不读 `mynetd.env` | procd `env` 要整份加载，否则 HOME/GATEWAYS 丢 |
| 9 | `$(basename` 等 make 函数 / A1 误报登录表单 | GUARD-OK 须贴在**违规那一行**；B2 不吃行内 GUARD-OK 时改测试实现 |
| 10 | OpenWrt 无 `sftp-server` | 用 `cat \| ssh 'cat > file'` 传文件 |

---

## 5. UX 对比结论（LuCI vs WebUI）

| | LuCI（路由器） | WebUI（本机） |
|---|---|---|
| 强项 | 状态轮询、系统信息全 | 结构清晰、任务聚焦 |
| 弱项 | 裸 API 错误、双启停入口 | 无展示刷新、长命令易假失败 |

已改：U1 错误人话化、U5 危险确认、U7 按钮唯一；WebUI U3/U4/U6。
详：`UX_LUCI_VS_WEBUI_20260929.md`。

---

## 6. 尚未闭环

| 项 | 说明 |
|---|---|
| bundle 驱动的 `mynet apply --auto` | 需 mynetd 拉到 `var/bundle.json`；现网路由暂自 `route.conf` 恢复 |
| 真 wg 隧道 | 架构已支持，未实测 |
| LuCI 登录流浏览器端到端 | 静态/启停已测；完整向导未走完 |
| 补丁版 gnb | 生产仍用原 `driver/gnb/bin/gnb`；若要 p2-route-proxy 需从 `mynet_gnb/packages` 重编 |
| 0.2 观察窗 | 建议 24h 看 proxy 分流与心跳是否只走 mynetd |

---

## 7. 相关文档

| 文档 | 内容 |
|---|---|
| `TEST_PLAN_OPENWRT_UI_INTERACTION.md` / `TEST_REPORT_…` | VM 交互/UI 测试 |
| `UX_LUCI_VS_WEBUI_20260929.md` | 体验对比 |
| `UPGRADE_PLAN_192_168_0_2.md` | 升级计划与 dry-run |
| `mynet_agent/.github/workflows/build_openwrt.yml` | SDK 出 ipk |
| `mynet_gnb/packages/README.md` | gnb 补丁包约定 |
