# 192.168.8.1 升级计划 — 目标 B（迁移到 agent 形态）

> 日期：2026-10-10（v2：用户裁定目标 = 形态 B）
> 目标机：**PVE VM 100 `OpenWRT` @ 宿主 `192.168.8.8`**（PVE 9.0.5，standalone）
> 节点：overlay `10.182.236.178`，node_id `3722810996882027`，zone「MyNet Nomadic Village」
> 环境（2026-10-10 用户澄清）：**公司节点、用户当前网络的公司主路由**；参照 .182 位于家里，是家庭旁路由，两者不在同一 LAN。
> 角色：**主路由**（WAN `eth1 192.168.1.191` / LAN `br-lan 192.168.8.1`，本机桌面与 PVE 宿主都靠它上网）
> 状态：**仅摸底 + 计划，未执行任何升级动作**
> 参照：`docs/UPGRADE_PLAN_192_168_0_2.md`（旁路由 .182 的同名计划，本计划复用其骨架）

---

## 0. 结论先行

**走 B 是对的，但现在还走不了**，卡三个硬缺口（都不在 .178 身上，在上游出包/安装链）：

1. **OpenWrt 出包腿不闭环** —— ctl 发行面 `mynet_agent` **无 openwrt 腿**；`lua`(ipk) 产品 `latest=null`；而本地 `make dist` 恒 `-tags embed`、全仓无 `EMBED` 开关 ⇒ **没有可直接下发的 OpenWrt agent 包**。
2. **`mynet install` 与 ipk 落位打架** —— 安装器按 `prefix/sbin` 校验二进制，默认 prefix 是 `/opt/mynet`，而 ipk 装到 `/usr/sbin` ⇒ 按现有文档命令在 OpenWrt 上会直接判「缺二进制」失败。
3. **主路由专属能力只覆盖一半** —— NAT/forward 的 gateway 分支只在旧 `scripts/firewall.mynet` 里，agent 侧只有出口 SNAT/client 分流；且机上那条下游回程路由（`192.168.9.0/24 via 192.168.8.209`）在新 SSOT（`bundle.network.routes`）里没有对应物。

⇒ 先把上面三项补齐（或明确降级口径），再谈 .178 的切换窗口。

---

## 1. 现状（2026-10-10 实测）

### 1.1 机器 / 宿主

| 项 | 值 |
|---|---|
| 宿主 | **192.168.8.8**，`pve`，PVE 9.0.5（9c5600b249dbfd2f），kernel 6.14.8-2-pve，**standalone**（无 corosync/cluster） |
| VM | **100 `OpenWRT`**（running，2 vCPU，mem 2048，`scsi0 local-lvm:vm-100-disk-0` 980M，`hostpci2/3` = 2× RTL8125 2.5GbE 直通） |
| 快照能力 | `local-lvm` = **lvmthin** ⇒ 支持 VM 快照；`qm listsnapshot 100` 当前**无任何快照** |
| 宿主自身上网 | PVE 默认路由 **`via 192.168.8.1`（即 VM 100 本身）** ⇒ **VM 100 停 = 宿主也失去上行**（见 §5 R1） |
| 目标机系统 | OpenWrt 24.10.7 r29197，`x86/64`，kernel 6.6.141；root ext4 **98.3M（可用 45.7M）**；guest 已运行 39 天（09-01 重启，qemu 进程自 04-21 未重启） |
| guest 网卡 | `eth0`(virtio, br-lan 成员, MAC `bc:24:11:46:81:e9`)、`eth1`(virtio, WAN dhcp, MAC `bc:24:11:9e:6f:55`) —— MAC 为用户在 guest 内改过 |
| 身份锚点 | FDB：178 的 eth0 MAC 学在 **`tap100i0`** 上 ⇒ 网卡确终结于 VM 100 |

### 1.2 MyNet 侧

| 项 | 值 |
|---|---|
| 安装形态 | **旧 LuCI Lua `APP_VERSION="2.1.6"`** + `/etc/init.d/mynet`（rc.common shell，START=99，`start()` 在 `:65`） |
| 二进制 | **无** `mynet`/`mynetd`/`mynet_gateway`；`opkg list-installed` 206 包内无 mynet |
| gnb | `/etc/mynet/driver/gnb/bin/gnb`，**`Dev 1.6.4`**，**不支持 p2 proxy**（`proxy.conf loaded`/`ingress_open`/`Features:` 全 0）；同目录 `gnb_linux_amd64.tgz` 是 `bugs.md` §6 手工残留 |
| 服务模型 | gnb 由 Lua `node.start_gnb` spawn 成 detached daemon（`daemon on`），**未纳 procd**（`ubus call service list` 无 mynet） |
| 自动机制 | **无 crontab、无心跳循环**；LuCI 日志最后活动 2026-09-01 |
| 配置 | `ifname gnb_tun_178` / `listen 9016` / `mtu 1450` / `zip auto` / `multi-socket on` / `es-argv --upnp` |
| uci 网络 | `network.lan`=br-lan(eth0) 192.168.8.1/24；`network.wan`=eth1 dhcp；**`network.mynet` device `gnb_tun_178`**；`firewall` zone `mynet` device `gnb_tun_178` + 4 条 forwarding + `firewall.mynet_include`→`/etc/mynet/scripts/firewall.mynet.include` |
| 运行态 | 隧道 up，`ip route` = `10.182.236.0/24 dev gnb_tun_178` + 4 条子网；tun in 3.223G；对端 `.182` 8.3ms |
| proxy | `PROXY_ENABLED="0"`，无 `table inet mynet_proxy`，`ip rule` 无 fwmark ⇒ **分流没跑** |
| 手工补丁 | `/etc/firewall.user` 两条 nft 转发规则；`/etc/rc.local` 一条 `192.168.9.0/24 via 192.168.8.209` |
| 出网 | DNS 正常；`https://ctl.mynet.club/d/apps.json` → 200；`wget/curl/tar/gzip/opkg/uci/nft` 齐备 |

---

## 2. 发行面与 OpenWrt 腿缺口

### 2.1 ctl 现状（只读）

| 产物 | 现状 | 走 B 的可用性 |
|---|---|---|
| `gnb` | `latest.stable=v1.6.0.a`；`v1.6.8-dev`(beta) 有 **`gnb_openwrt_amd64`**（sha256 `4974bfff…`） | ✅ 可手工取 |
| `mynet_agent` | `v0.1.2` stable，matrix = **linux{arm64,mipsel,amd64} / windows / darwin —— 无 openwrt** | ⚠️ 只能取 `linux/amd64` 静态包替代 |
| `lua`(LuCI ipk) | **`latest=null`**（无发布） | ❌ 无官方 ipk 源 |

### 2.2 仓库侧缺口（本次已复核的行）

| # | 证据 | 结论 |
|---|---|---|
| 1 | `mynet_agent/Makefile:76` | `DIST_MATRIX` **无 openwrt**；只有 darwin/linux(amd64,arm64,mipsle)/windows |
| 2 | `mynet_agent/Makefile:112` | dist 打 mynetd **恒 `-tags embed`**（重物打进二进制）⇒ 不适合 OpenWrt 瘦包 |
| 3 | `mynet_agent/mynet/cmd_install_openwrt.go:38,43-44` | `installOpenWrt(prefix,…)`，二进制按 **`prefix/sbin`** 校验 |
| 4 | `mynet_agent/.github/workflows/build_openwrt.yml:35-40,115,127` | 唯一 OpenWrt ipk 配方 checkout **私有仓 `mynet_openwrt-V2`**（`secrets.GH_PAT`）、只出 **Actions artifact**，**无 release / 无 ctl 发布** |
| 5 | `mynet_openwrt/Makefile:93-95,155-160,169-172` | LuCI ipk 的 postinst **写 cron `*/5 mynet-heartbeat`**、prerm 删 ⇒ 装它 = 引入**双心跳**风险 |

> 另：子代理只读调研指出（**未逐条复核**，动手前需自查）——`prefix` 默认 `/opt/mynet`（`prefix_unix.go:8-13`）而 ipk 落 `/usr/sbin`；`mynet config keys/refresh` 会**整份重写** `driver/gnb/conf/<id>/{node.conf,route.conf,address.conf,security/*}`（`driver/gnb.go:240-304`）；`bundle_envelope.go:275-335` 的接口名权威是 bundle `node.interface`。

---

## 3. B 的落地路径（阶段化，**均未执行**）

> 原则：**先补上游链，再碰 .178**。.178 只在最后一个阶段被切换。

### 阶段 B0 — 补齐出包/安装链（在仓库侧，不在目标机）
1. 给 `mynet_agent` 增 openwrt 出包腿（或明确「用 `linux/amd64` 静态包 + `EMBED=0` 瘦 mynetd」并落文档化）。
2. 解决 `mynet install` 的 prefix 与 ipk 落位冲突（`--prefix /usr` 或改默认），并让文档命令自洽。
3. 补主路由侧 firewall 能力（masq/forward 的 gateway 分支）或明确「由旧脚本继续承担」的降级口径。
4. 把 ipk/agent 产物接进 ctl 发布链（现在 agent 无 openwrt 腿、lua 无发布）。

### 阶段 B1 — 节点侧前置（只写控制面，不动本机服务）
5. 给 .178 建 `node_configs` 行：`config.ifname = gnb_tun_178`（**必须**，否则回落 legacy/报错）。
6. 让 bundle 覆盖机上现有 4 条子网路由 + 评估 `192.168.9.0/24 via 192.168.8.209` 怎么建模（§4）。
7. 备份（§6 Phase 0 全量）。

### 阶段 B2 — 维护窗内切换（高风险，需 PVE 控制台兜底）
8. `/etc/init.d/mynet stop`（Lua 精确停 gnb）→ 复核 tun/端口消失。
9. 摘掉一切老心跳（机上现无 crontab，属「确认无」而非「要删」）。
10. 落新件：`/usr/sbin/{mynet,mynetd}`、`/etc/init.d/{mynetd,mynet}`(procd)、LuCI/ubus 层。
11. `mynet install --prefix /usr --home /etc/mynet …`（参数以 B0 结论为准）。
12. 起 `mynetd` → `/etc/init.d/mynet start`（procd 接管 gnb）。
13. 立刻跑 §7 验收；不达标立即 §6 回滚。

### 阶段 B3 — 收尾
14. 摘 `mynet-heartbeat` cron（若被 ipk postinst 写入）；确认只留 mynetd 30s 心跳。
15. 保留备份 ≥7 天；更新 deployment-registry。

> **gnb 升级**（`Dev 1.6.4` → `1.6.8-dev/openwrt-amd64`）既是 B 的收益之一，也可作为**独立小步先做**（见 `UPGRADE_PLAN_192_168_0_2.md` 式步骤）。建议：先单独换 gnb 拿到 proxy 能力，再走 B 的形态迁移 —— 两个变更解耦，回滚面更小。

---

## 4. 主路由（.178）vs 旁路由（.182）—— 走 B 必须专门处理的差异

| 维度 | .178（主路由，本机） | .182（旁路由，参照） | 走 B 的风险 |
|---|---|---|---|
| **流量角色** | LAN 的网关，NAT + DNS + 转发全在它 | 只承担分流/中转 | agent 侧 firewall 覆盖不足时，**LAN 全网受影响** |
| **WAN** | `eth1` dhcp（192.168.1.191） | 与 .178 同构但非全网出口 | 主路由要保「LAN→WAN masq」；agent 侧只有出口 SNAT（`proxy_exit_firewall.go`）与 client 分流 ⇒ **gateway 分支仍在旧 sh 脚本里** |
| **默认路由** | 主表 default 走 WAN | 同 | `.178` proxy=关 ⇒ 不触发 `FullTunnelCmds` 改主表；但仍须在切换后**回读 default 未被隧道盖住** |
| **DNS** | 跑 dnsmasq 供 LAN | 有 smartdns 分流 | 新形态不得重写 `/etc/dnsmasq.d`；`.178` proxy 关 ⇒ 影响面小但要验证 |
| **下游回程** | 机上手工 `192.168.9.0/24 via 192.168.8.209` | 有 10 条站点网段的手工兜底 | 该路由**不在 `bundle.network.routes`**、也不是隧道口路由 ⇒ `mynet apply` 装不到、`--clear` 也不会删 ⇒ 会成「孤儿手工路由」，**必须显式保留或建模** |
| **瞬断影响** | 挂 = 整个 LAN（含 PVE 宿主 192.168.8.8）断 | 挂只影响分流 | **回滚窗口/PVE 快照是强制前置**，不能照搬 .182 剧本 |

---

## 5. 风险

| ID | 风险 | 级别 | 缓解 |
|---|---|---|---|
| **R1** | **VM 100 停 = PVE 宿主也失去上行**（宿主的默认路由就是 192.168.8.1）⇒ 回滚时可能连不上宿主 | **P0** | 回滚动作必须能走 **PVE 本地控制台/IPMI**；窗口前先确认控制台可用 |
| R2 | 主路由 firewall/NAT 覆盖不足（§4） | **P0** | B0 先补；切换后立即验 LAN 出网 + NAT |
| R3 | gnb 未纳 procd，停旧实例只能靠 Lua `stop_gnb`（PPID 匹配）；**禁 `pkill/killall/pidof`**（AGENTS.md §3） | P1 | 停后复核 tun/端口消失；失效则 pidfile+cmdline 精确停 |
| R4 | `mynet config keys/refresh` 整份重写 gnb conf ⇒ 可能冲掉 `zip auto`/`mtu 1450`/`es-argv --upnp`，并**重投影私钥** | P1 | 切换前 diff；私钥源以 `conf/local/keys/node.private` 为准 |
| R5 | OpenWrt 上**双心跳**（ipk postinst 写 cron + mynetd 30s） | P1 | B3 显式摘 cron |
| R6 | ipk `luci-app-mynet` 覆盖现网 LuCI 模块（2.1.6 → 2.1.8）后 ACL/菜单变化 | P2 | 备份 LuCI 模块；保留旧目录回滚位 |
| R7 | rootfs 仅剩 **45.7M** | P2 | 包只落 `/tmp`（tmpfs）；备份先量空间 |
| R8 | 手工补丁（`firewall.user` 两条 nft、`rc.local` 回程路由）**是否已被正式代码覆盖**未证 | P2 | 不顺手删；先立证再处置 |

---

## 6. 备份与回滚

### Phase 0 — 备份（强制，除本机已备的 keys 外）

```text
目标机:
  /etc/mynet/ 全量 tar
  /etc/init.d/mynet ; /usr/lib/lua/luci/{controller,model,view}/mynet*
  /etc/config/{network,firewall,dhcp} ; /etc/firewall.user ; /etc/rc.local
  nft list ruleset > backup-nft.txt ; ip route ; ip rule ; opkg list-installed
  /etc/mynet/driver/gnb/bin/  → bin.1.6.4.bak-<date>/
宿主 PVE (192.168.8.8):
  qm config 100 > vm100.conf.bak
  qm snapshot 100 pre-agent-migration    ← 整机回滚点（首选手段）
```

### 回滚

```text
一级（快，首选）：PVE 侧 qm rollback 100 pre-agent-migration
   ⚠️ 需先 qm stop 100；且此时 192.168.8.1 不存在 ⇒ 只能走 PVE 本地控制台
二级（细）：/etc/init.d/mynet stop → 恢复上表文件与 bin 备份 → /etc/init.d/mynet start
三级：逐个撤回 uci / nft / cron 改动
```

---

## 7. 验收（切换后）

| # | 项 | 通过标准 |
|---|---|---|
| V1 | 进程 | `mynetd` running；`MYNET_EXECUTOR=lua`；gnb 由 procd 纳管（`ubus call service list` 有实例） |
| V2 | 隧道 | `gnb_tun_178` UP，`10.182.236.178/24` 在（接口名与 bundle `node.interface` 一致） |
| V3 | **主路由本职** | LAN 出网正常；`iptables/nft` NAT 规则在；**默认路由仍走 WAN 未被隧道盖住** |
| V4 | 路由 | bundle 4 条子网路由装齐；`192.168.9.0/24 via 192.168.8.209` 仍在（或已建模） |
| V5 | 数据面 | `gnb_ctl -s` 对端 `ping_ts_sec` 刷新；ping `.182/.180/.184/.181` 通 |
| V6 | 心跳 | **只有 mynetd 一条**；back 上节点 online |
| V7 | DNS | dnsmasq 链未破；LAN 客户端解析正常 |
| V8 | 分流 | `PROXY_ENABLED` 仍为 0，防火墙 zone/`mynet_include` 未破 |
| V9 | 端侧 | 桌面 192.168.8.213 与 PVE 192.168.8.8 均正常上网 |

---

## 8. 待决 / 待复核

**待用户**
1. 是否先单独升 gnb（解耦小步）再走形态 B，还是一步到位。
2. 维护窗时间；并确认 **PVE 本地控制台**可用（R1）。

**动手前必须自查（CI 证不了 / 只在真机暴露）**
3. `mynet install --prefix /usr` 的真实行为（`MYNET_BIN`/PATH 是否全对齐 `/usr/sbin`）。
4. bundle 是否真给 .178 下发 `node.interface=gnb_tun_178`。
5. `firewall.mynet` 的 auto 判定在 .178 上是 gateway 还是 bypass（取决于 uci `network.wan`）。
6. `mynet config keys/refresh` 重写 gnb conf 后键值是否与现网一致。
7. `build_openwrt.yml` 在 CI 上是否真能出包（依赖私有 `mynet_openwrt-V2` + `GH_PAT`）。

---

## 附：本次只读取证

- 私钥与凭据备份：`~/secure-backup/mynet-178-keys-20261010-163734/`
  （`mynet-178-backup.tar` 0600 + `MANIFEST.md`；`.private`=`cc6ffaa9…`、`.public`=`641e4f0e…`、`credential.json`=`acd3b101…`，sha256 与机上逐字节一致）。
- 目标机全程只读，唯一写入是取证时把机上 leftover tgz 解到 `/tmp/.g178`（**已 `rm -rf`**）。
- 宿主 `192.168.8.8` 全程只读（`qm config/list/listsnapshot`、`bridge fdb`、`blkid`、`ip neigh` 等）。
