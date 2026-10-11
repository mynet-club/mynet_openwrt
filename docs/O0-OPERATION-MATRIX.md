# O0 现状与接口锁定 — 操作全量表 / 接口表 / fixture / 缺口

> 2026-10-10。本文是 `AGENT_INTEGRATION_PLAYBOOK.md` §4 的 O0 交付件（操作全量表 + 接口表 + 脱敏 fixture + 缺口小结）。
> 取证范围：`mynet_openwrt/` 全部 Lua/HTM/JS/ucode/init/脚本，以及支撑判定的 `mynet_agent` 执行器与 `mynet_ctl` 合同。
> 证据纪律：每条结论带 `file:line`（相对 workspace `mynet-club/`）；无代码证据的写「未取证」，不猜。
> **边界**：本文只登记现状与处置，不改任何业务行为；操作在 LuCI、执行器、localapi 三侧的收敛由 O1–O5 承担。

---

## 0. 目标线与判定口径

目标线（判定「归属」时的依据，来自 playbook §3 与 lifecycle-contract §1–§2）：

```text
系统能力 → mynet_agent 执行器（mynet / mynetd）；OpenWrt 上 procd 唯一控制 GNB
本机能力面 → mynetd localapi（127.0.0.1:8096）
LuCI 只是壳，不应直接做系统写入；浏览器只访问 LuCI 同源接口
桥（target）：rpcd/ubus 白名单方法 → 回环 localapi
```

处置词义：
- **保留**：本轮登记，不移除（playbook §5.7：guest/离线、密钥导入、配置导出、诊断先登记并保留）。
- **迁移**：改由 agent CLI / mynetd localapi / ubus 桥承接；LuCI 收敛为薄壳。
- **移除**：与目标线冲突或已死，O5/O1/O3 收口时下架。

写入类操作（`/etc/init.d`、`uci`、`nft`、`ip route`、写盘、spawn/kill 进程）一律**不得保留在 LuCI 直写**；下表中它们的「处置」即使标「保留（登记）」也仅指**本轮不删除**，落点仍是迁出。

---

## 1. 操作全量表（核心）

> 「后端调用」列：`Lua 函数` / `rpcd·ubus` / `调 localapi HTTP` / `直接 shell·uci·nft` / `调云端 API`。
> 「目标线归属」列取值：`agent CLI` / `mynetd localapi` / `ubus 桥` / `保留在 LuCI`。
> 入口路径相对 LuCI 前缀 `/cgi-bin/luci/admin/services/mynet`
> （`luasrc/controller/mynet.lua:23-226`；菜单项 `root/usr/share/luci/menu.d/luci-app-mynet.json`）。

### 1.1 认证 / 会话

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| A1 | 云端登录（GET 渲染登录页 / POST 提交） | `login`（无菜单） | `login.htm` 表单 `action=.../login` POST | `Lua auth_m.login`→`调云端 API POST /auth/login`，写 `/etc/mynet/conf/credential.json`(0600)，`cfg_m.set_mode("mynet")` | 写 | mynetd localapi（向导登录，token 只落本机） | 迁移 | `luasrc/controller/mynet.lua:515-577`；`luasrc/model/mynet/auth.lua:18-65`；`luasrc/view/mynet/login.htm:18`；`luasrc/model/mynet/credential.lua:34-51` |
| A2 | 登出 | `logout`（无菜单） | 页面/按钮跳转 `/logout` | `Lua auth_m.logout`→`调云端 API POST /auth/logout`，删 credential.json | 写 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:580-583`；`luasrc/model/mynet/auth.lua:71-79` |
| A3 | 区域（tenant）选择 | `zones/select`（无菜单） | `wizard.htm` 表单 `action=.../zones/select` POST | `Lua zone_m.set_current_zone`→写 `zone.json` | 写 | mynetd localapi（`/config/tenants`） | 迁移 | `luasrc/controller/mynet.lua:593-616`；`luasrc/view/mynet/wizard.htm:191`；`luasrc/model/mynet/zone.lua:60-62` |

> 登录态把关：页面用 `auth_m.ensure_valid()`（token 过期→refresh），失败重定向 login（`luasrc/controller/mynet.lua:276-295`；`luasrc/model/mynet/auth.lua:149-166`）。JSON API 用 `require_api_auth`（云端认证）/`require_local_api`（仅频率限制、**不查 MyNet 认证**）（`luasrc/controller/mynet.lua:360-389`）。后者是「本地操作不校验云端身份」的现状点。

### 1.2 向导 / 接入（首次配置）

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| B1 | 向导页渲染（自动选 zone / 拉节点列表） | `wizard`（无菜单） | 浏览器 GET，登录后未配置时跳入 | `Lua zone_m.get_zones`/`node_m.get_nodes`→`调云端 API`；单 zone 自动写 `zone.json` | 读+写 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:763-859` |
| B2 | 向导选节点（写入节点配置）= **接入** | `wizard/select_node`（无菜单） | `wizard.htm` 表单 `action=.../wizard/select_node` POST | `Lua cfg_m.generate_mynet_conf`（写 `mynet.conf` + 可能写 uci）+ `node_m.refresh_configs_bundle`（拉 bundle 写 node/route/address/keys） | 写 | agent CLI（`config status/keys/pull`＋`connect`）/ mynetd localapi（`POST /config/connect`） | 迁移 | `luasrc/controller/mynet.lua:862-888`；`luasrc/view/mynet/wizard.htm:290`；`luasrc/model/mynet/config.lua:202-318`；`luasrc/model/mynet/node.lua:314-408` |
| B3 | 设置页渲染（查 GNB 二进制/版本） | `settings`（菜单：Settings，order 50） | 菜单点击 | `Lua cfg_m.load_gnb_config` + `util.exec(gnb --version)` | 读 | 保留在 LuCI | 保留 | `luasrc/controller/mynet.lua:706-738`；`root/usr/share/luci/menu.d/luci-app-mynet.json:121-129` |
| B4 | 保存设置（use_system_gnb 开关） | `settings/save`（无菜单） | `settings.htm` 表单 POST | `Lua cfg_m.save_gnb_config`→写 `config.json` | 写 | 保留在 LuCI（配置落 `config.json`） | 保留 | `luasrc/controller/mynet.lua:741-754`；`luasrc/view/mynet/settings.htm:6`；`luasrc/model/mynet/config.lua:100-109` |

### 1.3 节点页（Node）

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| C1 | 节点页渲染（配置/列表/私钥/对端/路由） | `node`（菜单：Node，order 30） | 菜单点击 | `Lua node_m.get_single_node`（云端）、`read_local_configs`/`get_private_key`/`get_peer_keys`/`get_local_peers`（读盘）、`gnb_ctl_query`（shell `gnb_ctl -s`） | 读 | mynetd localapi + ubus 桥 | 迁移 | `luasrc/controller/mynet.lua:619-688`；`luasrc/model/mynet/node.lua:415-658` |
| C2 | 另存 node.conf/route.conf/address.conf | `api/node_save_conf` | `node.htm` `mnFetch(.../node_save_conf)` | `Lua node_m.write_local_config`→写 `driver/gnb/conf/<nid>/*.conf` + 副作用（`generate_mynet_conf`/`generate_route_conf`/`proxy.route_inject`） | 写 | agent CLI（config）/ mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1465-1552`；`luasrc/view/mynet/node.htm:619-620`；`luasrc/model/mynet/node.lua:221-238` |
| C3 | 导入配置包（预览/应用） | `api/node_import` | `node.htm` `mnFetch(.../node_import, step=preview\|apply)` | `Lua node_m.import_preview`（解压 tar.gz/zip 到 /tmp）/`import_apply`（cp 覆盖 node/route/address/keys + 写 mynet.conf） | 写 | agent CLI（import）/ mynetd localapi | 保留（登记，§5.7） | `luasrc/controller/mynet.lua:1555-1623`；`luasrc/view/mynet/node.htm:540,563`；`luasrc/model/mynet/node.lua:1554-1682` |
| C4 | 保存私钥（hex）+ 拉取自身公钥 | `api/node_save_key` | `mynet.js` `mnFetch(.../node_save_key)` | `Lua node_m.save_private_key`（写 `security/<nid>.private` 0600）+ `fetch_server_public_key`（`调云端 API GET /nodes/{id}/keys`） | 写 | agent CLI（key import）/ mynetd localapi | 保留（登记，§5.7） | `luasrc/controller/mynet.lua:1387-1412`；`htdocs/luci-static/resources/mynet/js/mynet.js:508`；`luasrc/model/mynet/node.lua:468-514,1491-1514` |
| C5 | 生成 GNB 密钥对并上传公钥 | `api/node_gen_key` | `mynet.js` `mnFetch(.../node_gen_key)` | `Lua node_m.generate_key_pair`（shell `gnb_crypto -c`）、`save_private_key`、`save_public_key`、`upload_public_key`（`调云端 API POST /nodes/{id}/keys`，带用户 JWT） | 写 | agent CLI（`config keys`）/ mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1431-1462`；`htdocs/luci-static/resources/mynet/js/mynet.js:575`；`luasrc/model/mynet/node.lua:1456-1485,1519-1544` |
| C6 | 切换节点（写配置 + 拉 bundle） | `api/node_switch` | `node.htm`/`node_manager.htm` `mnApi('node_switch')` | `Lua cfg_m.generate_mynet_conf` + `node_m.refresh_configs_bundle` | 写 | agent CLI / mynetd localapi（`/nodes/switch` 只切 UI 焦点） | 迁移 | `luasrc/controller/mynet.lua:1415-1425`；`luasrc/view/mynet/node.htm:584`；`luasrc/view/mynet/node_manager.htm:103` |
| C7 | 刷新节点配置（bundle/单文件） | `api/node_config` | `mynet.js` `mnFetch(.../node_config, type=all\|node\|route\|address)` | `Lua node_m.refresh_configs_bundle`/`refresh_single_config`（拉云端 config/route/index + peer keys，写盘） | 写 | agent CLI（`config pull`）/ mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1368-1384`；`htdocs/luci-static/resources/mynet/js/mynet.js:385,420`；`luasrc/model/mynet/node.lua:761-814` |
| C8 | 节点列表页（兼容重定向） | `node/manager`、`nodes` | 旧链接 | `http.redirect`→`node?tab=list` | — | 保留在 LuCI | 移除（纯重定向壳） | `luasrc/controller/mynet.lua:691-698` |

### 1.4 快捷启停 / 生命周期（Dashboard 与 Node 页按钮）

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| D1 | 启动 VPN | `api/vpn_start` | `index.htm` `mnApi('vpn_start')` | `Lua node_m.start_vpn`→`直接 shell /etc/init.d/mynet start` | 写 | agent CLI（`service start`）/ mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1295-1306`；`luasrc/view/mynet/index.htm:232`；`luasrc/model/mynet/node.lua:829-832` |
| D2 | 停止 VPN | `api/vpn_stop` | `index.htm` `mnApi('vpn_stop')` | 同上（`init.d stop`） | 写 | agent CLI / mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1308-1318`；`luasrc/view/mynet/index.htm:264`；`luasrc/model/mynet/node.lua:834-837` |
| D3 | 重启 VPN | `api/vpn_restart` | `index.htm` `mnApi('vpn_restart')` | 同上（`init.d restart`） | 写 | agent CLI / mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1320-1331`；`luasrc/view/mynet/index.htm:268`；`luasrc/model/mynet/node.lua:839-842` |
| D4 | 直接启动 GNB | `api/gnb_start` | 无活动调用者（无 view 引用） | `Lua node_m.start_gnb`→**Lua 直接 spawn `gnb &`**（脱离 procd）+ 状态机 + preflight | 写 | 归 procd（agent CLI `service`） | 移除（procd 唯一控制 GNB） | `luasrc/controller/mynet.lua:1334-1345`；`luasrc/model/mynet/node.lua:1282-1374` |
| D5 | 直接停止 GNB | `api/gnb_stop` | 无活动调用者 | `Lua node_m.stop_gnb`→按 conf 扫 pid + `kill`/`kill -9` + 清 gnb_es | 写 | 归 procd | 移除 | `luasrc/controller/mynet.lua:1347-1353`；`luasrc/model/mynet/node.lua:1376-1414` |
| D6 | 直接重启 GNB | `api/gnb_restart` | 无活动调用者 | `Lua node_m.restart_gnb`（stop+start） | 写 | 归 procd | 移除 | `luasrc/controller/mynet.lua:1355-1366`；`luasrc/model/mynet/node.lua:1416-1420` |
| D7 | 启动 mynet 服务（init.d） | `api/svc_start` | 无活动调用者 | `直接 shell /etc/init.d/mynet start` | 写 | agent CLI / mynetd localapi | 移除（与 D1/D2/D3 重复） | `luasrc/controller/mynet.lua:1629-1633` |
| D8 | 停止 mynet 服务（init.d） | `api/svc_stop` | 无活动调用者 | `直接 shell /etc/init.d/mynet stop` | 写 | agent CLI / mynetd localapi | 移除（重复） | `luasrc/controller/mynet.lua:1635-1639` |
| D9 | 重启 mynet 服务（init.d） | `api/svc_restart` | 无活动调用者 | `直接 shell /etc/init.d/mynet restart` | 写 | agent CLI / mynetd localapi | 移除（重复） | `luasrc/controller/mynet.lua:1641-1645` |
| D10 | 启动 mynetd 守护 | `api/mynetd_start` | 无活动调用者 | `Lua` 直接 `bin -c … &`（后台 spawn），读 `/var/run/mynetd.pid` | 写 | 归 procd（`/etc/init.d/mynetd`） | 移除（与 procd 冲突） | `luasrc/controller/mynet.lua:1647-1666` |
| D11 | 停止 mynetd | `api/mynetd_stop` | 无活动调用者 | `直接 shell /etc/init.d/mynetd stop` + 回退 `kill <pid>` | 写 | 归 procd | 移除 | `luasrc/controller/mynet.lua:1668-1675` |
| D12 | 重启 mynetd | `api/mynetd_restart` | 无活动调用者 | stop + 直接 `bin &` spawn | 写 | 归 procd | 移除 | `luasrc/controller/mynet.lua:1677-1693` |

> 说明：D7–D12 在 `luasrc/view/`、`htdocs/` 内**零引用**（本仓 grep），属历史入口。

### 1.5 Operations 页（service）与其服务操作

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| E1 | Operations 页渲染（status/network/peers/log/diagnose tab） | `service`（菜单：Operations，order 45） | 菜单点击 | `Lua` 读 `route.conf`/`ip route`/NAT 状态/`gnb_ctl -s`/`tail luci.log`/`cfg_m.get_node_id` | 读 | mynetd localapi + ubus 桥 | 迁移 | `luasrc/controller/mynet.lua:930-1013` |
| E2 | 服务启停/自启（mynet start/stop/restart/enable/disable） | `service/op`（POST service=mynet） | `service.htm` `mnSvcOp({service:'mynet',op:...})` | `直接 shell /etc/init.d/mynet <op>`（start/restart 前先 `ensure_firewall_zone`） | 写 | agent CLI / mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1025-1046`；`luasrc/view/mynet/service.htm:75-77` |
| E3 | 应用路由（reload_route） | `service/op`（service=network, op=reload_route） | `service.htm` 按钮 | `直接 shell sh route.mynet start`（内部转 `mynet apply --auto`） | 写 | agent CLI（`apply --auto`） | 迁移 | `luasrc/controller/mynet.lua:1049-1069`；`luasrc/view/mynet/service.htm:179`；`scripts/runtime/route.mynet:77-86` |
| E4 | 应用防火墙（reload_fw） | `service/op`（op=reload_fw） | `service.htm` 按钮 | `直接 shell sh firewall.mynet start --interface`（写 uci zone/device + nft masq + fw4 reload） | 写 | agent CLI（`apply` 平台后端） | 迁移 | `luasrc/controller/mynet.lua:1070-1082`；`luasrc/view/mynet/service.htm:259` |
| E5 | 提交并重载防火墙（reload_fw_commit） | `service/op`（op=reload_fw_commit） | `service.htm` 按钮 | `直接 shell uci commit firewall && /etc/init.d/firewall reload` | 写 | agent CLI（`apply`） | 迁移 | `luasrc/controller/mynet.lua:1083-1086`；`luasrc/view/mynet/service.htm:260` |
| E6 | 自启开关（initd_enable/disable） | `service/op`（op=initd_enable\|initd_disable） | 无活动调用者 | `直接 shell /etc/init.d/mynet enable\|disable` | 写 | agent CLI / mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1087-1092` |
| E7 | 出/入站 NAT 开关（set_nat） | `service/op`（op=set_nat, nat_type=outbound\|inbound） | `service.htm` 开关 | `直接 uci set firewall.@zone[..].masq` / `uci add/delete forwarding` + `uci commit` + `firewall reload` | 写 | agent CLI（`apply`） | 迁移 | `luasrc/controller/mynet.lua:1093-1130`；`luasrc/view/mynet/service.htm:367` |
| E8 | 防火墙 Zone 一键配置（fw_setup） | `service/op`（op=fw_setup）/ `api/fw_setup` | `service.htm`/`index.htm` 按钮 | `Lua sys_m.ensure_firewall_zone`→`sh firewall.mynet install`（uci network/zone/forwarding/include + `firewall restart`） | 写 | agent CLI（`apply` 平台后端） | 迁移 | `luasrc/controller/mynet.lua:1131-1137,2010-2014`；`luasrc/model/mynet/system.lua:215-235` |
| E9 | 防火墙 Zone 清除（fw_teardown） | `service/op`（op=fw_teardown）/ `api/fw_teardown` | `service.htm`/`index.htm`、`mynet.js` | `Lua sys_m.remove_firewall_zone`→`sh firewall.mynet uninstall` + uci 回退删除 + `firewall reload` | 写 | agent CLI（`apply`） | 迁移 | `luasrc/controller/mynet.lua:1138-1144,2017-2021`；`luasrc/model/mynet/system.lua:239-279` |
| E10 | 重应用 Masq（fw_apply_masq） | `service/op`（op=fw_apply_masq）/ `api/fw_apply_masq` | `index.htm` 健康修复按钮、`mynet.js` | `Lua sys_m.apply_firewall_masq`→`sh firewall.mynet start`（nft masq） | 写 | agent CLI（`apply`） | 迁移 | `luasrc/controller/mynet.lua:1145-1151,2024-2028`；`luasrc/view/mynet/index.htm:274`；`luasrc/model/mynet/system.lua:283-298` |
| E11 | Peers 视图（gnb_ctl -s 解析） | `api/gnb_nodes` | `service.htm` 轮询 | `Lua gnb_ctl_query`→`shell gnb_ctl -s`，`sys_m.parse_gnb_nodes` | 读 | mynetd localapi（`/node-status` peers） | 迁移 | `luasrc/controller/mynet.lua:1947-1985`；`luasrc/view/mynet/service.htm:404` |
| E12 | Service detail（日志+进程信息） | `api/service_detail` | 无活动调用者 | `Lua node_m.get_svc_state`/`preflight_check` + `ps -o etime/rss` + `sys_m.get_mynetd_status` | 读 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1760-1791` |
| E13 | 日志尾部（logs_tail） | `api/logs_tail` | `mynet.js` `mnFetch(.../logs_tail)`（3 处引用） | `直接 shell tail -N luci.log` | 读 | mynetd localapi（`/logs`） | 迁移 | `luasrc/controller/mynet.lua:1794-1801`；`htdocs/luci-static/resources/mynet/js/mynet.js:708` |

> 兼容重定向（纯壳，无动作）：`network`、`log`、`diagnose`、`gnb`（`luasrc/controller/mynet.lua:1196-1209,757-760,1941-1945,86-88`）→ 处置 **移除（随页面替换下架）**。

### 1.6 诊断 / 校验 / 依赖安装

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| F1 | Dashboard 状态读（vpn_status/iface/zone/node_id） | `api/status` | `mynet.js` `mnRefreshStatus`（GET） | `Lua node_m.gnb_is_running`/`get_vpn_service_status`/`get_vpn_interface_status`（读 pidfile+`/proc`+`ip link`） | 读 | mynetd localapi（`/node-status`） | 迁移 | `luasrc/controller/mynet.lua:1215-1235`；`htdocs/luci-static/resources/mynet/js/mynet.js:179` |
| F2 | 节点详情异步拉取（带 5 分钟缓存） | `api/node_info` | `index.htm`、`mynet.js` | `Lua node_m.get_single_node`→`调云端 API GET /nodes/{id}` | 读 | mynetd localapi（relay/`config/cloud`） | 迁移 | `luasrc/controller/mynet.lua:1239-1274`；`luasrc/view/mynet/index.htm:296` |
| F3 | 节点列表 / 区域列表 | `api/nodes` / `api/zones` | 页面/JS | `Lua node_m.get_nodes`/`zone_m.get_zones`→`调云端 API` | 读 | mynetd localapi（relay） | 迁移 | `luasrc/controller/mynet.lua:1276-1293` |
| F4 | Dashboard 统计 | `api/dashboard_stats` | `mynet.js` `mnFetch(.../dashboard_stats)` | `Lua sys_m.collect_metrics`（读 `/proc`）+ `node_m.get_svc_state` + `gnb_ctl -s` | 读 | mynetd localapi（`/metrics`+`/node-status`） | 迁移 | `luasrc/controller/mynet.lua:1734-1754`；`htdocs/luci-static/resources/mynet/js/mynet.js:632`；`luasrc/model/mynet/system.lua:566-637` |
| F5 | Pre-flight 校验 | `api/preflight` | `mynet.js` `mnFetch(.../preflight)` | `Lua node_m.preflight_check`（读 node/route/address/keys/tun） | 读 | mynetd localapi（`/node-status`） | 迁移 | `luasrc/controller/mynet.lua:1699-1705`；`htdocs/luci-static/resources/mynet/js/mynet.js:682`；`luasrc/model/mynet/node.lua:891-997` |
| F6 | 服务状态机 | `api/svc_state` | `mynet.js`（dashboard_stats 内） | `Lua node_m.get_svc_state`（读 `gnb_state.json` + 校验进程） | 读 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1707-1711`；`luasrc/model/mynet/node.lua:873-885` |
| F7 | 诊断检查 | `api/diagnose` | `mynet.js` `mnFetch(.../diagnose)` | `Lua` 逐项读文件/`gnb_ctl`/`lsmod`/`tail gnb.log` | 读 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1825-1935`；`htdocs/luci-static/resources/mynet/js/mynet.js:762` |
| F8 | 配置校验 | `api/validate_config` | 无活动调用者 | `Lua validator.validate_config`（读 config/cred/zone/mynet.conf 权限） | 读 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:1807-1812`；`luasrc/model/mynet/validator.lua:34-142` |
| F9 | 配置自动修复 | `api/auto_repair` | 无活动调用者 | `Lua validator.auto_repair`（建 config.json / `chmod 600` / `mkdir`） | 写 | 保留在 LuCI（本地修复） | 保留 | `luasrc/controller/mynet.lua:1814-1822`；`luasrc/model/mynet/validator.lua:149-202` |
| F10 | 安装系统依赖 | `api/install_system_deps` | `mynet.js` `mnFetch(.../install_system_deps)` | `Lua gnb_installer.check_deps`→`opkg install bash/kmod-tun/libcurl-gnutls4/ca-bundle` + `modprobe tun` | 写 | agent CLI（`mynet install` 主机准备） | 迁移 | `luasrc/controller/mynet.lua:2001-2007`；`htdocs/luci-static/resources/mynet/js/mynet.js:604`；`luasrc/model/mynet/gnb_installer.lua:35-114` |
| F11 | GNB 自动安装 | `api/gnb_auto_install` | `mynet.js`（4 处引用） | `Lua gnb_installer.start_auto_install`→拉 `ctl/d/apps.json`+manifest，后台 `sh` 下载解压到 `driver/gnb/bin` | 写 | agent CLI（`driver install` / `install`） | 迁移 | `luasrc/controller/mynet.lua:1992-1998`；`luasrc/model/mynet/gnb_installer.lua:608-732` |
| F12 | 查询 GNB 安装状态 | `api/gnb_install_status` | `mynet.js`（4 处引用） | `Lua gnb_installer.get_status`（读锁文件+日志尾） | 读 | agent CLI | 迁移 | `luasrc/controller/mynet.lua:2031-2036`；`luasrc/model/mynet/gnb_installer.lua:277-304` |
| F13 | 手工心跳 | `api/heartbeat` | 无活动调用者 | `Lua sys_m.submit_heartbeat`→`调云端 API POST /api/v2/monitor/heartbeat`（HMAC） | 写 | 归 mynetd（心跳唯一 owner） | 移除 | `luasrc/controller/mynet.lua:1717-1728`；`luasrc/model/mynet/system.lua:644-721` |

### 1.7 Proxy 分流

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| G1 | Proxy 页渲染 | `proxy`（无菜单，从 Plugins 进入） | `plugin.htm` 的 Configure 链接 | `Lua proxy_m.get_status`/`load_config`/`node_m.get_local_peers` | 读 | 保留在 LuCI（数据经桥）| 迁移 | `luasrc/controller/mynet.lua:2048-2083`；`luasrc/view/mynet/plugin.htm` |
| G2 | Proxy 状态 | `api/proxy_status` | `proxy.htm` `mnFetch(.../proxy_status)` | `Lua proxy_m.get_status`→`sh proxy.sh status --json` / `ipset`/`nft` 探测 | 读 | mynetd localapi（`/plugin/proxy`） | 迁移 | `luasrc/controller/mynet.lua:2085-2091`；`luasrc/view/mynet/proxy.htm:449`；`luasrc/model/mynet/proxy.lua:132-251` |
| G3 | Proxy 启动 | `api/proxy_start` | `proxy.htm` `mnApi('proxy_start')` | `Lua proxy_m.start`→`route_inject` + `bash proxy.sh generate` + 写 `proxy_policy_params.env` + `bash route_policy.sh start`（nft/ipset/ip rule）+ `unroute_foreign_dns`（清历史外部 DNS 主表路由；该层 2026-10-11 已下线） | 写 | agent CLI（Cloud 出口许可 → `apply`）(O4) | 迁移 | `luasrc/controller/mynet.lua:2093-2107`；`luasrc/view/mynet/proxy.htm:369`；`luasrc/model/mynet/proxy.lua:339-471,478-505` |
| G4 | Proxy 停止 | `api/proxy_stop` | `proxy.htm` `mnApi('proxy_stop')` | `Lua proxy_m.stop`→`route_policy.sh stop` + `route_restore` + 清状态 | 写 | agent CLI (O4) | 迁移 | `luasrc/controller/mynet.lua:2109-2119`；`luasrc/view/mynet/proxy.htm:370`；`luasrc/model/mynet/proxy.lua:518-541` |
| G5 | Proxy 重载 | `api/proxy_reload` | `proxy.htm` `mnApi('proxy_reload')` | `Lua proxy_m.reload`→`proxy.sh generate --force` + `route_policy.sh restart` | 写 | agent CLI (O4) | 迁移 | `luasrc/controller/mynet.lua:2121-2131`；`luasrc/view/mynet/proxy.htm:371`；`luasrc/model/mynet/proxy.lua:547-567` |
| G6 | Proxy 启用/停用 | `api/proxy_enable` / `api/proxy_disable` | `proxy.htm` 开关 | `Lua proxy_m.enable`（写 `proxy_role.conf` + hook + 若 gnb 在跑则 start）/`disable`（stop+route_restore+清 hook） | 写 | agent CLI (O4) | 迁移 | `luasrc/controller/mynet.lua:2133-2156`；`luasrc/view/mynet/proxy.htm:365`；`luasrc/model/mynet/proxy.lua:259-308` |
| G7 | Proxy 配置读写 | `api/proxy_config` | `proxy.htm`（GET/POST） | `Lua proxy_m.update_config`/`load_config`→写 `proxy_role.conf` | 写 | agent CLI (O4) | 迁移 | `luasrc/controller/mynet.lua:2202-2227`；`luasrc/model/mynet/proxy.lua:93-115` |
| G8 | Proxy 诊断指定 IP | `api/proxy_diagnose` | `proxy.htm` `mnFetch(.../proxy_diagnose)` | `Lua proxy_m.diagnose_ip`→`ip route get`/`ipset test`/`nft get element`/`traceroute` | 读 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:2184-2200`；`luasrc/view/mynet/proxy.htm:380`；`luasrc/model/mynet/proxy.lua:610-653` |
| G9 | 出口 IP 探测/连通性检查 | `api/proxy_net_detect` / `api/proxy_net_check` | `proxy.htm` `mnFetch` | `Lua proxy_m.net_detect`/`net_check`→`curl` 外部服务/目标 host | 读 | mynetd localapi | 迁移 | `luasrc/controller/mynet.lua:2158-2182`；`luasrc/view/mynet/proxy.htm:404,427`；`luasrc/model/mynet/proxy.lua:836-878` |

> 出口许可语义（playbook §3）：`network.proxy` 只有出口许可 `enabled/acl`；无许可、开放、白名单、撤销是不同状态，由 Cloud 统一 bundle 承载（O4 收口）。现状 Lua 自读 `proxy_role.conf`/`proxy_route.conf`（`luasrc/model/mynet/proxy.lua:16,60-115,411,439`）与云端无许可判定，属**待迁移**。

### 1.8 Guest 离线模式

| # | 操作名 | LuCI 入口（路径/菜单） | 调用者/触发点 | 后端调用 | 读/写 | 目标线归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|---|
| H1 | Guest 页渲染 | `guest`（无菜单，Dashboard 入口） | 浏览器跳转 | `Lua guest_m.load_config`/`is_initialized` + `cfg_m.get_gnb_bin` | 读 | 保留在 LuCI | 保留（登记，§5.7） | `luasrc/controller/mynet.lua:2234-2245` |
| H2 | 初始化 Guest 网络 | `api/guest_init` | `guest.htm` `mnGuestFetch('guest_init')` | `Lua guest_m.init_network`→`node_m.generate_key_pair`（shell `gnb_crypto`）为每节点生成密钥，写 node/route/address/keys + `guest.json` + `generate_mynet_conf` | 写 | 保留在 LuCI（离线模式，登记） | 保留（登记） | `luasrc/controller/mynet.lua:2248-2282`；`luasrc/view/mynet/guest.htm:132`；`luasrc/model/mynet/guest.lua:161-229` |
| H3 | 查询 Guest 节点 | `api/guest_nodes` | `guest.htm` 轮询 | `Lua guest_m.load_config` + `pgrep gnb` | 读 | 保留在 LuCI | 保留（登记） | `luasrc/controller/mynet.lua:2285-2302` |
| H4 | 新增 Guest 节点 | `api/guest_add` | `guest.htm` `mnGuestFetch('guest_add')` | `Lua guest_m.add_node`（生成密钥 + 写配置 + `generate_route_conf`） | 写 | 保留在 LuCI | 保留（登记） | `luasrc/controller/mynet.lua:2305-2322`；`luasrc/model/mynet/guest.lua:236-338` |
| H5 | 删除 Guest 节点 | `api/guest_delete` | `guest.htm` `mnGuestFetch('guest_delete')` | `Lua guest_m.delete_node`（`rm -rf` conf 目录 + 重写 route） | 写 | 保留在 LuCI | 保留（登记） | `luasrc/controller/mynet.lua:2325-2341`；`luasrc/model/mynet/guest.lua:344-384` |
| H6 | 导出 Guest 节点配置包 | `api/guest_export` | `guest.htm` 下载链接（GET） | `Lua guest_m.export_node_config`→`tar -czf`；`http` 回写文件流 | 读（导出） | 保留在 LuCI（§5.7 保留导出） | 保留（登记） | `luasrc/controller/mynet.lua:2344-2364`；`luasrc/view/mynet/guest.htm:37`；`luasrc/model/mynet/guest.lua:391-409` |
| H7 | 切换 Guest 活跃节点 | `api/guest_use` | `guest.htm` `mnGuestFetch('guest_use')` | `Lua` 改 `guest.json` + `generate_mynet_conf` + `ensure_route_conf` | 写 | 保留在 LuCI | 保留（登记） | `luasrc/controller/mynet.lua:2368-2402`；`luasrc/model/mynet/guest.lua:134-153` |
| H8 | 启动 Guest GNB | `api/guest_start` | 仅 `guest.htm.bak` 引用（**未安装**） | `Lua`→`pgrep -f 'gnb -c <conf>'` + kill + 后台 spawn gnb | 写 | 归 procd | 移除（procd 唯一控制 GNB） | `luasrc/controller/mynet.lua:2404-2449`；`luasrc/view/mynet/guest.htm.bak:61` |
| H9 | 停止 Guest GNB | `api/guest_stop` | 仅 `guest.htm.bak` 引用（未安装） | `Lua`→`pgrep -f 'gnb -c /etc/mynet'` + kill | 写 | 归 procd | 移除 | `luasrc/controller/mynet.lua:2452-2459`；`luasrc/view/mynet/guest.htm.bak:69` |
| H10 | 重置 Guest 网络 | `api/guest_reset` | `guest.htm` `mnGuestFetch('guest_reset')` | `Lua guest_m.reset`（kill gnb + `rm -rf` 节点目录 + 删 `guest.json` + 删 `mynet.conf`） | 写 | 保留在 LuCI | 保留（登记） | `luasrc/controller/mynet.lua:2462-2473`；`luasrc/model/mynet/guest.lua:415-425` |
| H11 | 导入 Guest 配置包 | `api/guest_import` | `guest.htm` `mnGuestFetch('guest_import', step=…)` | `Lua guest_m.import_preview`/`import_apply`（解压、校验、cp、写 `guest.json`）+ `cfg_m.set_mode("guest")` | 写 | 保留在 LuCI（§5.7 保留导入） | 保留（登记） | `luasrc/controller/mynet.lua:2476-2544`；`luasrc/model/mynet/guest.lua:435-656` |
| H12 | 切换运行模式（mynet/guest） | `api/set_mode` | `guest.htm` `mnGuestFetch('set_mode')` | `Lua cfg_m.set_mode`→写 `config.json` | 写 | 保留在 LuCI | 保留 | `luasrc/controller/mynet.lua:2547-2557`；`luasrc/view/mynet/guest.htm:100`；`luasrc/model/mynet/config.lua:26-30` |

> 安装包只装 `*.htm`（`mynet_openwrt/Makefile:40`），`guest.htm.bak` 不进包（`luasrc/view/mynet/guest.htm.bak`）。

### 1.9 启动链 / 周期任务（非 LuCI 点击，但驱动上述操作的系统侧）

| # | 名称 | 触发点 | 后端调用 | 读/写 | 归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|
| I1 | `/etc/init.d/mynet`（= `rc.mynet`）：start 用 procd 托管 gnb | 开机 / `init.d mynet start` | `procd_open_instance gnb` + `procd_set_param command gnb -c confdir`；随后调 `firewall.mynet`/`route.mynet` | 写 | agent CLI / procd | 迁移（init 归 `mynet install`，单一源码） | `scripts/runtime/rc.mynet:65-109` |
| I2 | `rc.mynet` stop：**把 gnb 启停委托给 `luci.model.mynet.node`** | `init.d mynet stop` | `lua -e` → `node.stop_gnb(nid)`（Lua 按 conf 扫 pid + kill） | 写 | 归 procd | 迁移/移除（不得脱离 procd） | `scripts/runtime/rc.mynet:120-171`（尤其 `:126-132,158-168`） |
| I3 | `/etc/init.d/mynetd`（ipk 版 `mynetd.init`） | 开机 / postinst | `procd` 托管 mynetd，设 `MYNET_EXECUTOR=lua`；**不加载 `mynetd.env`** | 写 | agent CLI / procd | 迁移 | `scripts/runtime/mynetd.init:9-21` |
| I4 | postinst 写 cron 心跳 + firewall install | ipk 安装 | 追加 `*/5 * * * * /usr/bin/mynet-heartbeat` 到 `/etc/crontabs/root`；`sh firewall.mynet install` | 写 | agent CLI | 迁移（心跳归 mynetd；O3 摘 cron 前先分离 peer-heal） | `Makefile:155-161,149-150` |
| I5 | cron 心跳脚本 + peer-heal | cron 每 5 分钟 | `lua -e run_daemon_heartbeat`（mynetd 在跑则 skip） + `_gnb_peer_heal`（判据 = `gnb_ctl -s` 无 PONG + ping 对端，冷却 900s/宽限 90s；不通则 `node.restart_gnb`） | 写 | agent CLI（心跳归 mynetd；peer-heal 留执行器/平台） | 迁移/收窄 | `scripts/shell/heartbeat.sh:40-127`；`luasrc/model/mynet/system.lua:729-848` |

### 1.10 ucode / rpcd / ACL

| # | 名称 | 入口 | 后端调用 | 读/写 | 归属 | 处置 | 证据 |
|---|---|---|---|---|---|---|---|
| J1 | ubus 对象 `mynet.system.status` | `ubus call mynet.system status` | `call_localapi("/api/v1/status")` → **返回 `{ok:true, note:"bridge stub", path:...}`** | 读 | ubus 桥 | 迁移（stub → 真实回环调用） | `luasrc/usr/lib/rpcd/ucode/mynet.uc:6-17` |
| J2 | ubus 对象 `mynet.system.system-json` | `ubus call mynet.system system-json` | `fs.readfile("/etc/mynet/var/system.json")` | 读 | ubus 桥 | 迁移 | `luasrc/usr/lib/rpcd/ucode/mynet.uc:19-29` |
| J3 | rpcd ACL `luci-app-mynet` | LuCI 会话授权 | `read.uci:[luci,network,system]`；`write.uci:[luci]` | — | ubus 桥 | 迁移（补 mynet 对象授权） | `root/usr/share/rpcd/acl.d/luci-app-mynet.json:1-11` |
| J4 | LuCI 菜单挂载 | 菜单树 | `admin/services/mynet` 声明 `depends.acl:[luci-app-mynet]` | — | 保留在 LuCI | 保留 | `root/usr/share/luci/menu.d/luci-app-mynet.json:2-11` |

> **取证关键**：`mynet.uc` 是唯一 ucode 桥文件，`call_localapi` 是硬编码 stub（`mynet.uc:6-8`）；且 **`Makefile` install 段未安装该文件**（`Makefile:29-128` 无 `usr/lib/rpcd/ucode`），ACL 也未授权 `mynet` 对象（`acl.d/luci-app-mynet.json` 只有 uci 权限）。即：桥既未部署、也未接线。

### 1.11 已知需特别标注项（前轮审查结论，逐条核实）

1. **Lua 的 config/apply 分派不满足新 connect 合同** — 核实成立。`executor_lua.go` 的 `luaRunnerScript` 对 `config` 只落到 `status/config` 分支，仅返回 `node_id/running/vpn_type/interface` 四字段（`mynet_agent/cmd/mynetd/executor_lua.go:271-282`）；而 `handleConfigConnect` 依赖 `config status --json` 的 `initialized/mode/active` 及 `config keys ensure/sync`、`config pull`、`apply --active`（`mynet_agent/mynetd/localapi/connect_api.go:44-104`）。Lua 侧 `refresh-*` 走 `mynet <cmd> --auto`（`executor_lua.go:233-255`），`apply` 只区分 `--clear`/`apply_routes`（`executor_lua.go:180-193`）。静态可证：Lua 执行器**产不出** connect 所需字段与语义。**接入必须显式交 Go**（O1）。
2. **ubus 桥是 stub** — 成立（见 J1；`mynet.uc:6-8`）。
3. **包内 init 与安装器生成的 init 不一致** — 成立。ipk `scripts/runtime/mynetd.init` 不加载 `/etc/mynet/mynetd.env`（`scripts/runtime/mynetd.init:9-21`），安装器生成的 `mynet_agent/mynet/units/openwrt_mynetd.init:17-19` 加载。两份 `mynet` 服务 init 差异更大：ipk `rc.mynet` 无 WG 分支、无 `bundle_tun_device`、无 `wait_for_tun`、无「可验证归属」的 gnb_es 清理（`scripts/runtime/rc.mynet:65-171` 对照 `mynet_agent/mynet/units/openwrt_mynet.init:20-247`）。
4. **`rc.mynet` 把 gnb 启停委托给 `luci.model.mynet.node`** — 成立。`stop()` 用 `lua -e` 调 `node.stop_gnb(nid)`（`scripts/runtime/rc.mynet:120-171`，含 `:158-168`）；`start_service` 已用 procd（`:86-93`），两者混用。

---

## 2. 接口表

> 「权限要求」列：LuCI 侧统一为 **LuCI 会话 + rpcd ACL `luci-app-mynet`**；再叠加应用层 `require_api_auth`（云端 token）或 `require_local_api`（仅频率限制）。
> 「资源上限」列：脚本/代码里现有的显式上限；无则写「未取证」。
> `未取证` 表示本仓静态代码未给出该值。

### 2.1 LuCI 同源 JSON 接口（`/cgi-bin/luci/admin/services/mynet/api/*`）

| 路径（action 名） | 请求形态 | 响应形态 | 权限 | 资源上限 | 证据 |
|---|---|---|---|---|---|
| `api/status` | GET | `{success, vpn_status, vpn_iface, zone, node_id}` | LuCI 会话 | 未取证 | `luasrc/controller/mynet.lua:1215-1235` |
| `api/node_info` | GET/POST | `{success, data:{...}}` 或 `{success:false,message}` | LuCI 会话 + `require_local_api` | `/tmp` 缓存 TTL 300s | `luasrc/controller/mynet.lua:1239-1274` |
| `api/nodes` / `api/zones` | GET/POST | `{success,data}` | 云端 `require_api_auth`（token）+ 频率 60/min | 频率 60/min | `luasrc/controller/mynet.lua:1276-1293,360-389` |
| `api/vpn_start`/`_stop`/`_restart` | POST | `{success,message,detail?,code?}` | `require_local_api`（不查云端） | 频率 60/min | `luasrc/controller/mynet.lua:1295-1331` |
| `api/gnb_start`/`_stop`/`_restart` | POST(+`node_id`) | `{success,message,detail?}` | `require_local_api` | 频率 60/min | `luasrc/controller/mynet.lua:1334-1366` |
| `api/node_config` | POST(`node_id`,`type`) | `{success,files,errors,warnings,method}` | 云端 `require_api_auth` | 未取证 | `luasrc/controller/mynet.lua:1368-1384` |
| `api/node_save_key` | POST(`node_id`,`key_hex` 128hex) | `{success,message,pub_hex?,pub_warn?}` | 云端 `require_api_auth` | key 必须 128 hex | `luasrc/controller/mynet.lua:1387-1412` |
| `api/node_switch` | POST(`node_id`) | `{success,message,redirect}` | 云端 `require_api_auth` | 未取证 | `luasrc/controller/mynet.lua:1415-1425` |
| `api/node_gen_key` | POST(`node_id`) | `{success,message,pub_hex}` | 云端 `require_api_auth` | 未取证 | `luasrc/controller/mynet.lua:1431-1462` |
| `api/node_save_conf` | POST(`config_type`,`content`) | `{success,message,path,warning?}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1465-1552` |
| `api/node_import` | POST(`step`,`file_data` base64,`filename`) | `preview` 对象 / `{success,node_id,message}` | `require_local_api` | base64 ≤ 1MB（`1048576`） | `luasrc/controller/mynet.lua:1555-1623`（`:1567-1569`） |
| `api/svc_start`/`_stop`/`_restart` | POST | `{success,message}` | `require_local_api` | 频率 60/min | `luasrc/controller/mynet.lua:1629-1645` |
| `api/mynetd_start`/`_stop`/`_restart` | POST | `{success,message}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1647-1693` |
| `api/preflight` | POST(`node_id?`) | `{success,data:{ok,checks}}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1699-1705` |
| `api/svc_state` | POST | `{success,data:{state,detail,updated}}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1707-1711` |
| `api/heartbeat` | POST(`node_id?`) | `{success,message,commands?,node_status?}` | 云端 `require_api_auth` | curl `-m 25`（`system.lua:822`） | `luasrc/controller/mynet.lua:1717-1728` |
| `api/dashboard_stats` | POST | `{success,metrics,svc_state,peers,node_id}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1734-1754` |
| `api/service_detail` | POST | `{success,svc_state,preflight,gnb_info,mynetd}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1760-1791` |
| `api/logs_tail` | POST(`lines`) | `{success,log,path}` | `require_local_api` | `lines>500` 截为 500 | `luasrc/controller/mynet.lua:1794-1801`（`:1797`） |
| `api/validate_config` | POST | `{success,data:{ok,checks}}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1807-1812` |
| `api/auto_repair` | POST | `{success,repair,after}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1814-1822` |
| `api/install_system_deps` | POST | `{success,steps,errors}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:2001-2007` |
| `api/fw_setup`/`_teardown`/`_apply_masq` | POST | `{success,message}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:2010-2028` |
| `api/gnb_nodes` | POST | `{success,ts,nodes:[...]}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:1947-1985` |
| `api/gnb_auto_install` | POST | `{ok,status,message,...}` | `require_local_api` | 下载 `-m 180` | `luasrc/controller/mynet.lua:1992-1998`；`gnb_installer.lua:531` |
| `api/gnb_install_status` | POST | `{success,data}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:2031-2036` |
| `api/diagnose` | POST | `{success,all_ok,checks,gnb_log}` | `require_local_api` | `tail -30 gnb.log` | `luasrc/controller/mynet.lua:1825-1935`（`:1926`） |
| `api/proxy_status` | POST | `{success,data:{running,layers,stats}}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:2085-2091` |
| `api/proxy_start`/`_stop`/`_reload`/`_enable`/`_disable` | POST(proxy 参数) | `{success,message}` / `{success:false,message}`(400) | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:2093-2156` |
| `api/proxy_config` | GET/POST | `{success,data}` / `{success,message}` | `require_local_api` | 未取证 | `luasrc/controller/mynet.lua:2202-2227` |
| `api/proxy_diagnose` | POST(`ip` IPv4) | `{success,data:{ip,checks}}` | `require_local_api` | traceroute `-m 3 -w 1` | `luasrc/controller/mynet.lua:2184-2200`；`proxy.lua:646` |
| `api/proxy_net_detect` | POST(`type=domestic\|proxy`) | `{success,data:{ip,raw}}` | `require_local_api` | curl `--max-time 10/15` | `luasrc/controller/mynet.lua:2158-2169`；`proxy.lua:839-842` |
| `api/proxy_net_check` | POST(`host`) | `{success,data:{reachable,http_code,time_ms,ip}}` | `require_local_api` | curl `--max-time 15` | `luasrc/controller/mynet.lua:2171-2182`；`proxy.lua:858-861` |
| `api/guest_init`/`_add`/`_delete`/`_use`/`_start`/`_stop`/`_reset`/`_import` | POST | `{success,data?}` | **无 MyNet 认证**，仅 `check_rate_limit`（10–20/min） | init/use/start 10/min；add/delete 20/min；reset/import 5/min | `luasrc/controller/mynet.lua:2248-2544`；频率见 `:2249,2306,2326,2369,2405,2453,2463,2477` |
| `api/guest_nodes` | POST | `{success,data,vpn_running}` | 无认证 | — | `luasrc/controller/mynet.lua:2285-2302` |
| `api/guest_export` | GET(`node_id`) | 二进制 `application/gzip` 附件 | 无认证 | 未取证 | `luasrc/controller/mynet.lua:2344-2364` |
| `api/set_mode` | POST(`mode=mynet\|guest`) | `{success,mode}` | 无认证 | 10/min | `luasrc/controller/mynet.lua:2547-2557` |
| `service/op` | POST(`service`,`op`,`tab`,`nat_type?`,`value?`) | JSON(`_ajax=1`) 或渲染 service 页 | `auth_or_local`（宽松，未登录也放行本地） | `sleep 1` | `luasrc/controller/mynet.lua:1016-1193` |

> 说明：`require_local_api` 与 guest API **都不校验云端登录**（`luasrc/controller/mynet.lua:381-389`；guest 各端点仅 `check_rate_limit`）。频率限制按 `REMOTE_ADDR` 哈希落 `/tmp/mynet_rate`（`:236-272`）。这是现状点，属 O2「逐方法冻结读/写 ACL」的对象。

### 2.2 mynetd localapi（`127.0.0.1:8096`，目标回环端）

| 路径 | 方法 | 请求形态 | 响应形态 | 权限 | 资源上限 | 证据 |
|---|---|---|---|---|---|---|
| `/api/v1/status` | GET | — | `{success,data:{daemon,listen,role}}` | Host/Origin 校验 | 未取证 | `spec/local-api.md:217,245-252` |
| `/api/v1/node-status` | GET | — | 六态机 `{state,actions,labels,...}` | Host/Origin | 未取证 | `spec/local-api.md:218` |
| `/api/v1/system.json` | GET | — | detector 快照 / 404 | Host/Origin | 未取证 | `spec/local-api.md:219` |
| `/api/v1/logs` | GET only | `?lines=`（默认 80，>400 忽略） | `{success,data}` 脱敏 | Host/Origin | lines>400 忽略 | `spec/local-api.md:220` |
| `/api/v1/metrics` | — | 分派 `mynet metrics --json` | 子进程原件 | Host/Origin | 未取证 | `spec/local-api.md:221` |
| `/api/v1/command` | POST only | `{"argv":[…]}`（argv[0] 白名单 22 项） | `{argv,stdout,stderr,bin}`（脱敏） | Host/Origin | 执行器 60s | `spec/local-api.md:222`；`executor_lua.go:64` |
| `/api/v1/command-result` | POST only | `{id,ok,message,source}` | — | Host/Origin | 未取证 | `spec/local-api.md:223` |
| `/api/v1/config/{mode,tenants,active,keys,identity,runtime,cloud,prepare,connect,apply}`、`/api/v1/plugins` | GET/POST | 读 GET；`mode/keys/active/apply` 写 POST | JSON / 阶段 | Host/Origin | 未取证 | `spec/local-api.md:224` |
| `/api/v1/config/connect` | POST | — | `{success,stage,message,steps:[{id,name,state}],retryable}`；失败停后续步骤 | Host/Origin | 与身份/密钥/apply 共享互斥闸（409 `operation_in_progress`, `Retry-After:2`） | `spec/local-api.md:233-243`；`connect_api.go:28-107` |
| `/api/v1/nodes`、`/nodes/switch` | GET；POST | switch：`{node_id}` | `{data:{focus,parallel,nodes}}` | Host/Origin；缺 node_id→400 | 未取证 | `spec/local-api.md:225-226` |
| `/api/v1/plugin/proxy` | GET\|POST | — | proxy 意图态 | Host/Origin | 未取证 | `spec/local-api.md:227` |
| `/api/v1/wizard/{login,logout,state}` | login/logout POST only | `{email,password,device_name,device_fingerprint}` | back 信封解包；token 落 `credential.json`(0600) | Host/Origin；失败沿用 back 码 | 未取证 | `spec/local-api.md:228` |
| `/api/v1/relay?path=` | ANY | — | **back 状态码+body 原样透传**（不套本机信封） | 路径白名单（`relaypolicy`，先 deny 后 allow，含 `%` 拒） | 未取证 | `spec/local-api.md:229,150-174` |
| `/gui/`、`/gui/api/v1/*` | GET | — | mynet_gui 产物；`/gui/api/*` 内部改写成 relay | Host/Origin | 未取证 | `spec/local-api.md:230` |
| 覆盖层报文 | — | — | 统一 `{success,message,data?,stage?,steps?,…}`；**无共享信封结构体，字段逐处涌现** | — | — | `spec/local-api.md:92-122` |

### 2.3 云端（back）接口（由 Lua 直连，目标改为经 localapi/relay）

| 路径 | 方法 | 请求形态 | 响应形态 | 权限 | 资源上限 | 证据 |
|---|---|---|---|---|---|---|
| `/auth/login` | POST | `{email,password,device_name,device_fingerprint}` | `{success,data:{user,tenant_id,auth_token,refresh_token,auth_token_expires_in}}` | 无（登录） | curl `-m 30` | `luasrc/model/mynet/auth.lua:18-65`；`luasrc/model/mynet/api.lua:8` |
| `/auth/logout` | POST | `{}` + Bearer | — | Bearer token | `-m 30` | `luasrc/model/mynet/auth.lua:71-79` |
| `/auth/refresh-token` | POST | `{refresh_token}` | `{success,data:{auth_token,refresh_token,…}}` | — | `-m 30` | `luasrc/model/mynet/auth.lua:87-119` |
| `/auth/verify-token` | GET | — | `{success,data:{valid,user_id}}` | Bearer | `-m 30` | `luasrc/model/mynet/auth.lua:126-141` |
| `/user/tenants/` | GET | — | `{success,data:[{tenant_id,name,domain,status,…}]}` | Bearer | `-m 30` | `luasrc/model/mynet/zone.lua:16-47` |
| `/nodes`、`/nodes/{id}` | GET | `?page=&per_page=` | `{success,data:{nodes|…}}` | Bearer + `X-Tenant-ID` + `X-Device-Fingerprint` | `-m 30` | `luasrc/model/mynet/node.lua:70-86,415-426`；`api.lua:72-87` |
| `/nodes/{id}/config?render_conf=1`、`/route/node/{id}?render_conf=1`、`/services/indexes?render_conf=1` | GET | — | `text/plain` 渲染配置 | Bearer + `X-Tenant-ID` | `-m 30` | `luasrc/model/mynet/node.lua:93-121` |
| `/nodes/{id}/config-bundle` | GET | — | `{files:{…},keys:{…},warnings}`（裸对象） | Bearer + `X-Tenant-ID` | `-m 30`；404 区分 not_supported | `luasrc/model/mynet/api.lua:164-190` |
| `/nodes/{id}/keys` | GET / POST | POST `{public_key}` | `{success,data:{key:{public_key}}}` | Bearer | `-m 30` | `luasrc/model/mynet/node.lua:1491-1544` |
| `/nodes/{id}/router-keys` | POST | `{}` | `{data:{peer_id:hex\|{public_key}}}` | Bearer | `-m 30`；404→not_supported | `luasrc/model/mynet/api.lua:197-212` |
| `/nodes/{id}/status` | PATCH | `{status}` | `{success}` | Bearer | `-m 30` | `luasrc/model/mynet/node.lua:146-158` |
| `/api/v2/monitor/heartbeat` | POST | `{status,uptime,…,vpn_interfaces:[…]}` | `{success,commands?}` | `X-Node-Id`+`X-Timestamp`+`X-Node-Signature`（HMAC-SHA256） | curl `-m 25` | `luasrc/model/mynet/api.lua:219-237`；`system.lua:800-830` |
| `/api/v1/command-result`（回灌，本机回环） | POST | `{id,ok,message,source}` | — | 无 | curl `-m 3` | `luasrc/model/mynet/system.lua:465-478` |

> `api.lua` 全局超时常量 `DEFAULT_TIMEOUT = 30`（`luasrc/model/mynet/api.lua:8`），逐调用可覆盖为 `-m 3/25/180`。

### 2.4 rpcd / ubus

| 对象/方法 | 请求 | 响应 | 权限 | 资源上限 | 证据 |
|---|---|---|---|---|---|
| `mynet.system.status` | `{}` | `{ok:true,note:"bridge stub",path:"/api/v1/status"}` | rpcd ACL（**未授权** mynet 对象） | 未取证 | `luasrc/usr/lib/rpcd/ucode/mynet.uc:6-17` |
| `mynet.system.system-json` | `{}` | `{json:<raw>}` / `{error}` | 同上 | 未取证 | `luasrc/usr/lib/rpcd/ucode/mynet.uc:19-29` |
| ACL `luci-app-mynet` | — | `read.uci` / `write.uci` | 仅 `uci` 权限 | — | `root/usr/share/rpcd/acl.d/luci-app-mynet.json:1-11` |

### 2.5 系统命令 / 脚本接口（被 Lua 或 init 调用）

| 目标 | 形态 | 权限 | 资源上限 | 证据 |
|---|---|---|---|---|
| `/etc/init.d/mynet {start,stop,restart,status,enable,disable,install}` | init 脚本（procd） | root | `stop` 内 `sleep 2` | `scripts/runtime/rc.mynet:65-239` |
| `/etc/init.d/mynetd {start,stop,enable,disable}` | init 脚本（procd） | root | — | `scripts/runtime/mynetd.init:9-29` |
| `/etc/mynet/scripts/route.mynet {start,stop,status}` | 薄封装 → `mynet apply --auto\|--clear` | root | — | `scripts/runtime/route.mynet:36-102` |
| `/etc/mynet/scripts/firewall.mynet {install,uninstall,start,stop,restart,status}` | uci/nft/ft 脚本 | root | `/etc/init.d/firewall restart` | `scripts/runtime/firewall.mynet:522-571,666-706` |
| `/etc/mynet/scripts/proxy/proxy.sh generate` | 生成 `proxy_route.conf`/`proxy_outbound.txt` | root | — | `scripts/proxy/proxy.sh:24-138` |
| `/etc/mynet/scripts/proxy/route_policy.sh {start,stop,restart,server_start,server_stop,dns_start,dns_stop}` | nft/ipset/ip rule/route | root | — | `scripts/proxy/route_policy.sh:272-709` |
| `/usr/bin/mynet-heartbeat` | cron 包装 → `lua -e run_daemon_heartbeat` + `_gnb_peer_heal` | root | 日志保留 500 行；peer-heal 冷却 900s/宽限 90s | `scripts/shell/heartbeat.sh:29-127` |
| `gnb_ctl -s -b conf/<nid>/gnb.map` | 只读 peer 状态 | root | — | `luasrc/controller/mynet.lua:321-329` |
| `gnb_crypto -c -p … -k …` | 生成 GNB 密钥对 | root | mktemp 临时目录 | `luasrc/model/mynet/node.lua:1456-1485` |

### 2.6 执行器资源上限（跨平台合同，来自 agent/合同文档）

| 项 | 值 | 证据 |
|---|---|---|
| Lua 执行器单次执行上限 | 60s（`context.WithTimeout(…, 60*time.Second)`） | `mynet_agent/cmd/mynetd/executor_lua.go:64` |
| `config/connect` / 身份密钥 apply 互斥 | 409 + `operation_in_progress` + `Retry-After:2` | `mynet_agent/mynetd/localapi/connect_api.go:10-24` |
| 执行器装配（OpenWrt） | `MYNET_EXECUTOR=lua` → `api.Ops = execLua` | `mynet_agent/cmd/mynetd/main.go:126-130` |
| LuCI/rpcd 可承受调用时长 | 未取证（playbook §6 明确要求 O0 量出；本仓无该数值） | `mynet_openwrt/docs/AGENT_INTEGRATION_PLAYBOOK.md:120` |

---

## 3. 脱敏 fixture 清单（九种场景）

> 约定：所有真实标识用占位——`node_id=<redacted>`、`token=<redacted>`、`key=<redacted>`、`zone_id=<redacted>`；不得写入任何真实密钥/令牌/节点 ID 明文。
> 「当前是否有可复现途径」：有则给命令/文件；无则写「待造」。

| # | 场景 | 触发条件 | 期望前端显示 | 期望后端状态 | 可复现途径 |
|---|---|---|---|---|---|
| S1 | 未初始化 | 无 `mynet.conf`／`NODE_ID=0`；无 `credential.json` | 显示 landing（`wizard?tab=landing`）或跳登录；`is_mynet_configured()==false` | 无有效身份/配置；`preflight` 报 `node_id not configured` | **有**：`rm -f /etc/mynet/conf/{mynet.conf,credential.json}` 后访问 `/cgi-bin/luci/admin/services/mynet/wizard`（`luasrc/controller/mynet.lua:790-798`；`config.lua:37-47`） |
| S2 | 已接入 | `mynet.conf` 有 `NODE_ID=<redacted>`、`zone.json` 有 zone、node/route/address/keys 齐、gnb 在跑 | Dashboard 显示 `vpn_status=running`、接口 `UP`、Nodes/Peers 列出 | 进程存活、tun 就绪、路由已装 | **有（需真设备）**：`gnb_is_running` + `get_vpn_interface_status`（`node.lua:1262-1280,1426-1450`）；端到端需隔离环境 |
| S3 | 离线（节点不在线） | gnb 进程不存在或 tun `DOWN` | 状态点 `stopped`/`DOWN`；健康检查提示「GNB service stopped」 | `get_vpn_service_status()=="stopped"`；`svc_state` 验证进程后置 `error`（crashed?） | **有**：`node.stop_gnb(<node_id>)` 或直接停进程；`node.lua:820-827,873-885`；`system.lua:950-959` |
| S4 | 过期会话 | `credential.json` 的 `expires_at` 已过，refresh 亦失败 | 页面重定向 login；API 返回 401 `not authenticated`；向导显示 need_login | `auth.ensure_valid()` 返回 nil；localapi `config/connect`→401 `need_login` | **有**：把 `credential.json.expires_at` 改为过去时间并令 refresh 失败（断网/删 refresh_token）；`credential.lua:63-68`；`auth.lua:149-166`；`connect_api.go:36-41` |
| S5 | 版本冲突 | `node.conf` 的 `nodeid` 与当前节点不一致，或 `route.conf` 首条 nodeid 不匹配 | 健康检查「Config ID mismatch」，引导 Re-configure（wizard） | `preflight_check` 报 `node_conf_id_match`/`route_conf_id_match` 失败 | **有**：改 `driver/gnb/conf/<nid>/node.conf` 的 `nodeid <other>` 占位值（用假 ID）；`node.lua:914-943`；`system.lua:900-947` |
| S6 | 出口无许可 | `network.proxy`（Cloud）无许可；本地 `proxy_role.conf` `PROXY_ENABLED=0` | Proxy 页显示未启用；不显示分流层 | 出口不开放；`proxy.get_status().running=false` | **部分有**：`proxy.disable()` 后可观察（`proxy.lua:291-308`）；「Cloud 无许可」判定**待造**（现由 Cloud bundle 承载，O4 未落地） |
| S7 | 出口开放 | `network.proxy.enabled`（Cloud）为开放；本地 `PROXY_ENABLED=1` | Proxy 页显示 running + 分流层 | nft/ipset 已装、`route_policy.sh` 已生效 | **有（需真设备）**：`proxy.enable()`/`proxy.start()`（需 GNB 在跑）；`proxy.lua:259-289,339-471` |
| S8 | 白名单 | `PROXY_POLICY=whitelist`（`proxy_role.conf`），`PROXY_PEERS` 指向 peer | 显示「whitelist」匹配模式，peer 列表 | `proxy_route.conf` 用 `interip.txt` 正向匹配 | **有**：`proxy.update_config({proxy_mode="client",node_region="domestic",proxy_policy="whitelist"})`（`proxy.lua:20-23,60-115`） |
| S9 | 撤销 | 先授权出口，再撤销（Cloud 撤销 / `proxy.disable()`） | Proxy 页回到未启用；不残留分流规则 | `route_restore` 清注入段；`route_policy.sh stop` 清 nft/ip rule/route table | **部分有**：`proxy.disable()` 可复现本地撤销（`proxy.lua:291-308,789-802`）；「Cloud 撤销后不得由旧 conf 自动恢复」**待造**（合同 §3，O4 落地） |

> fixture 覆盖度小结：S1–S5、S7、S8 有本地可复现途径；S6/S9 的「Cloud 许可态」部分只有本地撤销可复现，**Cloud 无许可/撤销**的真实链路未落地（O4），登记为「待造」。所有场景的**真前端像素**与**真设备数据面**未在本轮取证（playbook §8：本轮未跑 LuCI 浏览器操作与真设备）。

---

## 4. 缺口小结（分类 + 收口包）

| 类 | 缺口 | 代表证据 | 收口包 |
|---|---|---|---|
| **G-a 仍在 LuCI 直做系统写入** | 直接 `init.d`/`uci`/`nft`/`ip route`/写盘/spawn·kill | `controller/mynet.lua:1038,1084,1101,1112-1126,1664,1690`；`node.lua:1333-1336,1400-1402,1726-1750`；`system.lua:215-298`；`proxy.lua:489-490` | O1（执行器/装配）· O3（生命周期/规则）· O4（Proxy）· O5（页面收敛） |
| **G-b 后端是 stub** | ubus 桥 `call_localapi` 硬编码 stub；且未部署、ACL 未授权 | `luasrc/usr/lib/rpcd/ucode/mynet.uc:6-8`；`Makefile:29-128`（无 ucode install）；`acl.d/luci-app-mynet.json:1-11` | O2（本地管理桥） |
| **G-c 两份 init 漂移** | ipk `mynetd.init` 不加载 `mynetd.env`；`rc.mynet` 与安装器 `openwrt_mynet.init` 差异大（WG/接口权威/tun 等待/归属清理） | `scripts/runtime/mynetd.init:9-21` vs `mynet_agent/mynet/units/openwrt_mynetd.init:17-19`；`scripts/runtime/rc.mynet:65-171` vs `mynet_agent/mynet/units/openwrt_mynet.init:20-247` | O1（init 单一源码）· O6（打包） |
| **G-d 生命周期多入口 / 脱离 procd** | `api_gnb_start/stop/restart`、`api_mynetd_*`、guest `gnb` spawn；`rc.mynet` stop 委托 Lua `stop_gnb` | `controller/mynet.lua:1334-1366,1647-1693,2404-2459`；`rc.mynet:120-171`；`node.lua:1282-1420` | O1·O3 |
| **G-e 接入合同断层** | Lua `config` 只回 4 字段；`apply` 不产运行投影；connect 依赖 `initialized/mode/active/keys/pull` | `executor_lua.go:271-282,180-193,233-255` vs `connect_api.go:44-104` | O1 |
| **G-f 心跳/cron 未收窄** | postinst 写 cron 心跳；`rc.mynet` 与 `mynetd` 双驱动；peer-heal 判据依赖已下架 `mynet_proxy` 改造后的 `gnb_ctl -s` | `Makefile:155-161`；`system.lua:644-648,729-733`；`heartbeat.sh:64-127` | O3 |
| **G-g 双写权威 / JWT 参与后台** | Lua 用用户 JWT 拉 bundle/上传公钥/上报心跳；与 Go 配置权威双份 | `node.lua:314-408,1519-1544`；`system.lua:644-721`；`auth.lua:18-141` | O4（Cloud/Local apply 统一）· O1 |
| **G-h 本地操作不校验云端身份** | `require_local_api` 与 guest API 只做频率限制 | `controller/mynet.lua:381-389`；guest 端点 `:2249,2306,…` | O2（逐方法冻结读/写 ACL） |
| **G-i 死代码/重复入口** | 重定向壳路由、无引用的 `api_svc_*`/`api_mynetd_*`/`api_gnb_*`、未安装的 `runtime/modules/*.sh`、未渲染的 `status/log/diagnose/node_manager.htm` | `controller/mynet.lua:691-698,86-88,1196-1209`；`Makefile:29-128`（无 modules）；`controller` 无 `render("mynet/status")` | O5·O6 |
| **G-j Proxy 自读 conf / 无 Cloud 许可判定** | Lua 自读 `proxy_role.conf`/`proxy_route.conf`；出口许可/撤销未接统一 bundle | `proxy.lua:16,60-115,411,439` | O4 |

---

## 5. 未取证清单

- LuCI/rpcd 可承受的**单次调用时长**与**最大请求/响应体**（playbook §6 要求 O0 量出）——本仓静态代码未给出；`未取证`。
- `api/status`、`api/node_config`、`api/node_switch`、`api/node_gen_key`、`api/node_save_conf`、`api/svc_state`、`api/dashboard_stats`、`api/service_detail`、`api/validate_config`、`api/auto_repair`、`api/fw_*`、`api/gnb_install_status`、`api/proxy_*`（多数写端点）、`service/op` 的**显式资源上限**——`未取证`（代码仅频率限制 60/min，无体量/时长闸）。
- guest `guest_export` 响应体上限、`guest_init` 节点数上限（代码限 2–10 个节点，`guest.lua:166`；导出无上限）——导出上限 `未取证`。
- 「Cloud 出口无许可」「Cloud 撤销」的真实链路可复现性——**待造**（O4 未落地）。
- 真设备上的前端像素与数据面允许/拒绝行为——本轮**未取证**（playbook §8：本轮未跑 LuCI 浏览器操作与真设备）。

---

## 7. 执行进度（2026-10-11 · O2/O3/O5）

> 矩阵是**目标态裁定**；本节记**已执行**了什么，避免把「已落地」当「待办」重做。
> 每项均设备实证（`.182` ImmortalWrt 24.10 x86_64）。

| 范围 | 落到哪一步 |
|---|---|
| O2 桥 | rpcd ucode 桥 + ACL（读 10/写 6）已上设备；`session access` 正负判定通过；HTTP `/ubus` 路径实证；三方一致性门禁 `scripts/tools/check_bridge_acl.sh`（桥⇄ACL⇄`bridge.lua`）挂 `make test` |
| O3 | `util.lua:M.exec_status` 取**最后一次** marker，修「成功却回 exit 1」 |
| O5 客户端 | 新增 `luasrc/model/mynet/bridge.lua`（页面唯一本地读写入口，方法表冻结 16 项） |
| **已迁移** | `api_get_status` 附 `bridge` 字段；**D1/D2/D3** `api_vpn_{start,stop,restart}` 走 `bridge.service`（保契约 + 桥缺失回落） |
| **浏览器实测** | 登录 `.182` LuCI：Dashboard 渲染（Running / gnb_tun_16 UP / Start-Stop-Restart 齐）；点 **Restart** → 页面 toast **「VPN restarted」**（走桥路径）；页面内 `fetch(api/status)` → 200 且 `bridge.daemon=mynetd`；Node 页「Node Manager →」链接 = `node?tab=list`；两页**无控制台报错** |
| **已移除** | **D4–D6** `api/gnb_*`、**D7–D9** `api/svc_*`、**D10–D12** `api/mynetd_*`、**F13** `api/heartbeat`、**H8/H9** `api/guest_{start,stop}`（12 个，均无活动调用者、均直写系统）；**C8** `node/manager`+`nodes` 重定向壳（含 node.htm 链接、menu.d、node_manager.htm） |
| **未迁移（耦合，勿机械替换）** | 写侧 `api_node_switch`/`api_node_config`/`api_proxy_enable` 等改走桥会**改变行为**（Lua 现写 conf/驱动引擎），须与 O4 的 proxy/云同步切换配套；读侧 `api_logs_tail`（luci.log）与桥 `/logs`（mynetd）**数据源不同**。均需浏览器验证 + 引擎切换，不在本轮 |
| **未迁移（O1-③ 依赖 O5）** | `rc.mynet`/`route.mynet` 直连的 Lua 启停/拆脚本，待上述页面改走桥后退役 |

---

## 8. 复核方法（可重跑）

```bash
# 路由全集
grep -n 'entry({' mynet_openwrt/luasrc/controller/mynet.lua
# 后端 JSON 接口全集
grep -n 'call("api_' mynet_openwrt/luasrc/controller/mynet.lua
# 页面渲染目标
grep -n 'tmpl.render("mynet/' mynet_openwrt/luasrc/controller/mynet.lua
# 视图/JS 触发点
grep -rn "mnApi(\|mnFetch(\|mnSvcOp(\|mnGuestFetch(" mynet_openwrt/luasrc/view mynet_openwrt/htdocs
# 直接系统写入（init.d/uci/nft/ip route）
grep -rn "init.d\|uci \|nft \|ip route" mynet_openwrt/luasrc/model/mynet
# ubus 桥 stub 与 ACL
sed -n '1,40p' mynet_openwrt/luasrc/usr/lib/rpcd/ucode/mynet.uc
sed -n '1,20p' mynet_openwrt/root/usr/share/rpcd/acl.d/luci-app-mynet.json
# 双 init 对照
diff mynet_openwrt/scripts/runtime/mynetd.init mynet_agent/mynet/units/openwrt_mynetd.init
```
